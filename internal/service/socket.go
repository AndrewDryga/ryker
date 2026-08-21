package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/reportcanvas"
	"github.com/AndrewDryga/responder/internal/slackdismiss"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func (s *Service) consumeSocket(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case event, ok := <-s.socket.Events():
			if !ok {
				return
			}
			switch event.Type {
			case socketmode.EventTypeConnected:
				s.socket.SetConnected(true)
			case socketmode.EventTypeDisconnect, socketmode.EventTypeConnectionError,
				socketmode.EventTypeInvalidAuth:
				s.socket.SetConnected(false)
			case socketmode.EventTypeEventsAPI:
				s.admitEventsAPI(ctx, event)
			case socketmode.EventTypeInteractive:
				s.admitInteraction(ctx, event)
			case socketmode.EventTypeSlashCommand:
				s.admitSlashCommand(ctx, event)
			}
		}
	}
}

func (s *Service) admitEventsAPI(ctx context.Context, event socketmode.Event) {
	if event.Request == nil {
		return
	}
	envelopeID := event.Request.EnvelopeID
	outer, ok := event.Data.(slackevents.EventsAPIEvent)
	if !ok {
		if pointer, pointerOK := event.Data.(*slackevents.EventsAPIEvent); pointerOK && pointer != nil {
			outer = *pointer
			ok = true
		}
	}
	if !ok || outer.TeamID != s.cfg.Slack.TeamID {
		_ = s.socket.Ack(*event.Request)
		return
	}
	var wrapper struct {
		EventID   string `json:"event_id"`
		EventTime int64  `json:"event_time"`
	}
	_ = json.Unmarshal(event.Request.Payload, &wrapper)
	if wrapper.EventID == "" {
		wrapper.EventID = "envelope:" + envelopeID
	}
	input := core.SlackInput{
		EnvelopeID: envelopeID, EventID: wrapper.EventID, TeamID: outer.TeamID,
		ReceivedAt: s.now().UTC(),
	}
	if wrapper.EventTime > 0 {
		input.ReceivedAt = time.Unix(wrapper.EventTime, 0).UTC()
	}
	outcome, directChannelJoin := s.classifyEventsAPIInput(ctx, outer, &input)
	switch outcome {
	case dropMessage:
		_ = s.socket.Ack(*event.Request)
		return
	case retryMessage:
		return
	}
	var err error
	if directChannelJoin {
		_, err = s.store.AdmitSlackChannelJoin(ctx, input)
	} else {
		bindCanonicalSlackMessageInputID(&input)
		_, err = s.store.AdmitSlackInput(ctx, input)
		if err == nil {
			if scheduleErr := s.scheduleExternalMessageReconciliation(ctx, input); scheduleErr != nil {
				s.log.Error(
					"schedule external Slack lifecycle reconciliation",
					"envelope", envelopeID,
					"input", input.ID,
					"error", scheduleErr,
				)
			}
		}
	}
	if err != nil {
		s.log.Error("persist Slack event before acknowledgement", "envelope", envelopeID, "error", err)
		return
	}
	if err := s.socket.Ack(*event.Request); err != nil {
		s.log.Warn("acknowledge Slack event", "envelope", envelopeID, "error", err)
	}
}

// classifyEventsAPIInput fills input from the inner Slack event and reports
// what to do with it, plus whether the event is a direct channel join — which
// takes a different admission path because a join has no message to key on.
//
// Splitting this from admitEventsAPI separates two questions that were tangled
// in one 160-line switch: what kind of event is this, and what does the socket
// consumer do about it. The consumer is single-threaded, so anything it holds
// delays admission of every event behind it; keeping the acknowledgement rules
// in one small place is how that stays reviewable.
func (s *Service) classifyEventsAPIInput(
	ctx context.Context,
	outer slackevents.EventsAPIEvent,
	input *core.SlackInput,
) (messageOutcome, bool) {
	switch inner := outer.InnerEvent.Data.(type) {
	case *slackevents.AppHomeOpenedEvent:
		if inner == nil || inner.User == "" {
			return dropMessage, false
		}
		// Opening the Messages tab is not work, because the prompts above it are
		// configuration rather than a Slack write.
		//
		// This app declares features.agent_view in
		// deploy/slack-app-manifest.yaml, and that manifest already carries the
		// three suggested prompts statically. Responder used to answer every
		// Messages tab open by calling assistant.threads.setSuggestedPrompts to
		// install a near-identical list at runtime, and Slack answered
		// internal_error every single time — 8 of 8 rows on one deployment, 4 of
		// 4 on the other, not one success since the code was written. The
		// prompts were there the whole time; the API call was a second,
		// failing copy of a setting that already worked. So a Messages tab open
		// is acknowledged and dropped, and costs nothing.
		if inner.Tab != "home" {
			return dropMessage, false
		}
		input.Kind = inputAppHome
		input.UserID = inner.User
	case *slackevents.ReactionAddedEvent:
		if inner == nil {
			return dropMessage, false
		}
		return s.classifyReaction(
			ctx, input, "reaction_added", inner.User, inner.ItemUser,
			inner.Reaction, inner.Item, inner.EventTimestamp,
		), false
	case *slackevents.ReactionRemovedEvent:
		if inner == nil {
			return dropMessage, false
		}
		return s.classifyReaction(
			ctx, input, "reaction_removed", inner.User, inner.ItemUser,
			inner.Reaction, inner.Item, inner.EventTimestamp,
		), false
	case *slackevents.MemberJoinedChannelEvent:
		if inner == nil || inner.User != s.identity.BotUserID || inner.Channel == "" {
			return dropMessage, false
		}
		input.Kind = "channel_joined"
		input.ChannelID = inner.Channel
		input.MessageTS = inner.EventTimestamp
		input.UserID = inner.Inviter
		return admitMessage, true
	case *slackevents.AppMentionEvent:
		if inner == nil || inner.BotID != "" || foreignSource(inner.SourceTeam, outer.TeamID) {
			return dropMessage, false
		}
		input.Kind = "mention"
		input.ChannelID = inner.Channel
		input.ThreadTS = inner.ThreadTimeStamp
		input.MessageTS = inner.TimeStamp
		input.UserID = inner.User
		input.Text = inner.Text
		input.Attachments = slackInputAttachments(inner.Files)
	case *slackevents.MessageEvent:
		// A message can be a channel join in disguise, which setMessageInput
		// reports by flipping this flag.
		directChannelJoin := false
		return s.setMessageInput(ctx, input, inner, outer.TeamID, &directChannelJoin),
			directChannelJoin
	default:
		return classifyChannelLifecycleEvent(input, outer.InnerEvent.Data), false
	}
	return admitMessage, false
}

// classifyReaction resolves the reaction target and reports what to do. A
// failed lookup is deliberately a retry rather than a drop: the decision is
// unknown, and dropping would silently discard a signal Slack will not resend.
func (s *Service) classifyReaction(
	ctx context.Context,
	input *core.SlackInput,
	kind string,
	userID string,
	itemUserID string,
	reaction string,
	item slackevents.Item,
	eventTS string,
) messageOutcome {
	admit, err := s.setReactionInput(
		ctx, input, kind, userID, itemUserID, reaction, item, eventTS,
	)
	if err != nil {
		s.log.Error(
			"resolve Slack reaction target",
			"channel", item.Channel,
			"message", item.Timestamp,
			"error", err,
		)
		return retryMessage
	}
	if !admit {
		return dropMessage
	}
	return admitMessage
}

// classifyChannelLifecycleEvent handles the events that say a channel changed
// state rather than that something was said in it. They are grouped because
// they are one shape — a channel, sometimes an actor, and a resulting state —
// and because an unrecognized event lands here and is dropped, which is the
// correct default for an event type Responder does not model.
func classifyChannelLifecycleEvent(input *core.SlackInput, event any) messageOutcome {
	switch inner := event.(type) {
	case *slackevents.ChannelDeletedEvent:
		if inner == nil {
			return dropMessage
		}
		setLifecycleInput(input, inner.Channel, "", core.ChannelDeleted, inner.Type)
	case *slackevents.GroupDeletedEvent:
		if inner == nil {
			return dropMessage
		}
		setLifecycleInput(input, inner.Channel, "", core.ChannelDeleted, inner.Type)
	case *slackevents.ChannelArchiveEvent:
		if inner == nil {
			return dropMessage
		}
		setLifecycleInput(input, inner.Channel, inner.User, core.ChannelArchived, inner.Type)
	case *slackevents.GroupArchiveEvent:
		if inner == nil {
			return dropMessage
		}
		setLifecycleInput(input, inner.Channel, "", core.ChannelArchived, inner.Type)
	case *slackevents.ChannelUnarchiveEvent:
		if inner == nil {
			return dropMessage
		}
		setLifecycleInput(input, inner.Channel, inner.User, core.ChannelActive, inner.Type)
	case *slackevents.GroupUnarchiveEvent:
		if inner == nil {
			return dropMessage
		}
		setLifecycleInput(input, inner.Channel, "", core.ChannelActive, inner.Type)
	default:
		return dropMessage
	}
	return admitMessage
}

// messageOutcome is what admitEventsAPI should do with a Slack message event.
type messageOutcome int

const (
	// admitMessage persists the input, then acknowledges.
	admitMessage messageOutcome = iota
	// dropMessage acknowledges without persisting: the message is genuinely
	// not for Responder, so Slack should stop redelivering it.
	dropMessage
	// retryMessage returns without acknowledging because a lookup failed and
	// the decision is unknown. Slack redelivers, and the durable event ID
	// keeps that from creating duplicate work.
	retryMessage
)

// setMessageInput fills in a Slack message input and reports what to do with
// it. It owns the message-shaped rules — own-bot suppression, the app_mention
// overlap, watched external apps, and channel retention — so admitEventsAPI
// stays a router over event types.
func (s *Service) setMessageInput(
	ctx context.Context,
	input *core.SlackInput,
	inner *slackevents.MessageEvent,
	teamID string,
	directChannelJoin *bool,
) messageOutcome {
	if inner == nil || foreignSource(inner.SourceTeam, teamID) {
		return dropMessage
	}
	message := normalizedSlackEventMessage(inner)
	if (message.SubType == slack.MsgSubTypeChannelJoin ||
		message.SubType == slack.MsgSubTypeGroupJoin) &&
		message.User == s.identity.BotUserID {
		input.Kind = "channel_joined"
		input.ChannelID = inner.Channel
		input.MessageTS = message.Timestamp
		input.UserID = message.Inviter
		*directChannelJoin = true
		return admitMessage
	}
	if s.identity.BotUserID != "" &&
		strings.Contains(message.Text, "<@"+s.identity.BotUserID+">") {
		// Slack also delivers this request as app_mention. Admit only that
		// event so one human message cannot consume two agent requests.
		return dropMessage
	}
	ownBot := (s.identity.BotID != "" && message.BotID == s.identity.BotID) ||
		message.User == s.identity.BotUserID
	externalBot := message.BotID != "" || message.SubType == "bot_message"
	switch {
	case ownBot:
		return dropMessage
	case externalBot:
		watched, err := s.proactiveEnabled(ctx, inner.Channel)
		if err != nil {
			s.log.Error(
				"resolve proactive Slack setting",
				"channel", inner.Channel,
				"error", err,
			)
			return retryMessage
		}
		if !watched {
			rules, ruleErr := s.matchingStandingRules(ctx, core.SlackInput{
				Kind:      "bot_message",
				ChannelID: inner.Channel,
				Text:      message.Text,
			})
			if ruleErr != nil {
				s.log.Error(
					"match standing rules for Slack app message",
					"channel", inner.Channel,
					"error", ruleErr,
				)
				return retryMessage
			}
			watched = len(rules) > 0
		}
		if !watched || !supportedExternalMessageSubtype(inner.SubType) {
			return dropMessage
		}
		input.Kind = "bot_message"
		input.UserID = core.FirstNonempty(message.BotID, message.User)
	case humanMessageSubtype(inner.SubType) && message.User != "":
		input.Kind = "message"
		if strings.HasPrefix(inner.Channel, "D") {
			input.Kind = "direct"
		}
		input.UserID = message.User
	default:
		return dropMessage
	}
	if input.UserID == "" {
		return dropMessage
	}
	input.ChannelID = inner.Channel
	input.ThreadTS = message.ThreadTimestamp
	input.MessageTS = message.Timestamp
	input.Text = message.Text
	input.Attachments = slackInputAttachments(message.Files)
	if input.Kind == "message" {
		admit, err := s.shouldAdmitChannelMessage(ctx, *input)
		if err != nil {
			s.log.Error(
				"decide whether to retain Slack channel message",
				"channel", input.ChannelID,
				"message", input.MessageTS,
				"error", err,
			)
			return retryMessage
		}
		if !admit {
			return dropMessage
		}
	}

	return admitMessage
}

func (s *Service) setReactionInput(
	ctx context.Context,
	input *core.SlackInput,
	kind string,
	userID string,
	itemUserID string,
	reaction string,
	item slackevents.Item,
	eventTS string,
) (bool, error) {
	if s.identity.BotUserID == "" || userID == "" || userID == s.identity.BotUserID ||
		item.Type != "message" || item.Channel == "" || item.Timestamp == "" || eventTS == "" {
		return false, nil
	}
	reaction, err := decisionpkg.NormalizeSlackReactionName(reaction)
	if err != nil {
		return false, nil
	}
	delivery, deliveryErr := s.store.GetSentSlackMessageDelivery(
		ctx,
		item.Channel,
		item.Timestamp,
	)
	if deliveryErr != nil && !errors.Is(deliveryErr, store.ErrNotFound) {
		return false, deliveryErr
	}
	if itemUserID != s.identity.BotUserID && errors.Is(deliveryErr, store.ErrNotFound) {
		return false, nil
	}
	input.Kind = kind
	input.ChannelID = item.Channel
	input.MessageTS = eventTS
	input.UserID = userID
	input.ActionID = reaction
	input.ActionValue = item.Timestamp
	if deliveryErr == nil {
		input.ThreadTS = delivery.ThreadTS
	}
	s.invalidateSlackHistory(item.Channel)
	return true, nil
}

func normalizedSlackEventMessage(event *slackevents.MessageEvent) slack.Message {
	message := slack.Message{Msg: slack.Msg{
		User: event.User, Text: event.Text, Timestamp: event.TimeStamp,
		ThreadTimestamp: event.ThreadTimeStamp, SubType: event.SubType,
		BotID: event.BotID, Blocks: event.Blocks,
	}}
	if event.Message != nil {
		message.Msg = *event.Message
		if message.Timestamp == "" {
			message.Timestamp = event.TimeStamp
		}
		if message.ThreadTimestamp == "" {
			message.ThreadTimestamp = event.ThreadTimeStamp
		}
		if message.User == "" {
			message.User = event.User
		}
		if message.BotID == "" {
			message.BotID = event.BotID
		}
		if message.SubType == "" && event.SubType != slack.MsgSubTypeMessageChanged {
			message.SubType = event.SubType
		}
	}
	message.Text = slackui.NormalizedMessageText(message)
	return message
}

func supportedExternalMessageSubtype(subtype string) bool {
	return subtype == "" || subtype == slack.MsgSubTypeBotMessage ||
		subtype == slack.MsgSubTypeMessageChanged
}

func humanMessageSubtype(subtype string) bool {
	return subtype == "" || subtype == slack.MsgSubTypeFileShare
}

func slackInputAttachments(files []slack.File) []core.SlackAttachment {
	result := make([]core.SlackAttachment, 0, len(files))
	for _, file := range files {
		downloadURL := strings.TrimSpace(core.FirstNonempty(file.URLPrivateDownload, file.URLPrivate))
		name := strings.TrimSpace(filepath.Base(file.Name))
		if name == "" || name == "." {
			name = "attachment"
		}
		if file.ID == "" {
			continue
		}
		result = append(result, core.SlackAttachment{
			ID: file.ID, Name: name, MediaType: strings.TrimSpace(file.Mimetype),
			Size: int64(file.Size), URLPrivate: downloadURL,
		})
	}
	return result
}

func (s *Service) shouldAdmitChannelMessage(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	if input.ChannelID == "" || input.MessageTS == "" {
		return false, nil
	}
	if _, err := s.store.FindIncidentForConversation(
		ctx,
		input.ChannelID,
		slackReplyThread(input),
	); err == nil {
		return true, nil
	} else if !errors.Is(err, store.ErrNotFound) {
		return false, err
	}
	continuing, err := s.isRecentWatchConversation(ctx, input)
	if err != nil || continuing {
		return continuing, err
	}
	proactive, err := s.proactiveEnabled(ctx, input.ChannelID)
	if err != nil || proactive {
		return proactive, err
	}
	setup, err := s.shouldAdmitConfigurationMessage(ctx, input)
	if err != nil || setup {
		return setup, err
	}
	rules, err := s.matchingStandingRules(ctx, input)
	if err != nil {
		return false, err
	}
	return len(rules) > 0, nil
}

func (s *Service) isRecentWatchConversation(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	if input.Kind != "message" {
		return false, nil
	}
	since := s.now().UTC().Add(-s.cfg.Slack.ContinuationWindow.Duration)
	if input.ThreadTS != "" {
		// A reply in an exact Slack thread remains part of that conversation even
		// after the short top-level continuation window expires.
		since = time.Time{}
	}
	return s.store.HasRecentWatchReply(
		ctx,
		input.ChannelID,
		input.ThreadTS,
		input.MessageTS,
		since,
	)
}

func setLifecycleInput(
	input *core.SlackInput,
	channelID string,
	userID string,
	state core.ChannelState,
	eventType string,
) {
	input.Kind = "channel_lifecycle"
	input.ChannelID = channelID
	input.UserID = userID
	input.ActionID = string(state)
	input.ActionValue = eventType
}

func (s *Service) admitInteraction(ctx context.Context, event socketmode.Event) {
	if event.Request == nil {
		return
	}
	callback, ok := event.Data.(slack.InteractionCallback)
	if !ok {
		if pointer, pointerOK := event.Data.(*slack.InteractionCallback); pointerOK && pointer != nil {
			callback = *pointer
			ok = true
		}
	}
	if !ok || callback.Team.ID != s.cfg.Slack.TeamID {
		_ = s.socket.Ack(*event.Request)
		return
	}
	if callback.Type == slack.InteractionTypeMessageAction &&
		callback.CallbackID == "responder_investigate_message" {
		input := core.SlackInput{
			EnvelopeID:  event.Request.EnvelopeID,
			EventID:     "shortcut:" + event.Request.EnvelopeID,
			Kind:        "shortcut",
			TeamID:      callback.Team.ID,
			ChannelID:   callback.Channel.ID,
			ThreadTS:    callback.Message.ThreadTimestamp,
			MessageTS:   callback.Message.Timestamp,
			UserID:      callback.User.ID,
			Text:        callback.Message.Text,
			Attachments: slackInputAttachments(callback.Message.Files),
			ActionID:    callback.CallbackID,
			ActionValue: callback.Message.User,
			ReceivedAt:  s.now().UTC(),
		}
		if input.ThreadTS == "" {
			input.ThreadTS = input.MessageTS
		}
		if input.ChannelID == "" || input.MessageTS == "" || input.UserID == "" {
			_ = s.socket.Ack(*event.Request)
			return
		}
		if _, err := s.store.AdmitSlackInput(ctx, input); err != nil {
			s.log.Error(
				"persist Slack message shortcut before acknowledgement",
				"envelope", input.EnvelopeID,
				"error", err,
			)
			return
		}
		if err := s.socket.Ack(*event.Request); err != nil {
			s.log.Warn("acknowledge Slack message shortcut", "error", err)
		}
		return
	}
	if len(callback.ActionCallback.BlockActions) != 1 {
		_ = s.socket.Ack(*event.Request)
		return
	}
	action := callback.ActionCallback.BlockActions[0]
	// Acknowledged either way — the operator picked something and Slack retries
	// an unanswered interaction — but dropped rather than admitted, because an
	// input with no action id would travel the whole control lane to be refused
	// at the end of it.
	actionID, actionValue, routable := slackui.ControlSelection(action)
	if !routable {
		s.log.Warn("drop Slack menu selection that carries no action",
			"envelope", event.Request.EnvelopeID, "action", action.ActionID)
		_ = s.socket.Ack(*event.Request)
		return
	}
	input := core.SlackInput{
		EnvelopeID:  event.Request.EnvelopeID,
		EventID:     "interaction:" + event.Request.EnvelopeID,
		Kind:        "action",
		TeamID:      callback.Team.ID,
		ChannelID:   core.FirstNonempty(callback.Container.ChannelID, callback.Channel.ID),
		ThreadTS:    core.FirstNonempty(callback.Container.ThreadTs, callback.Message.ThreadTimestamp),
		MessageTS:   core.FirstNonempty(callback.Container.MessageTs, callback.Message.Timestamp),
		UserID:      callback.User.ID,
		ActionID:    actionID,
		ActionValue: actionValue,
		ReceivedAt:  s.now().UTC(),
	}
	// Ephemeral dismissal uses its response URL and never becomes durable work.
	if actionID == slackui.ActionDismissMessage && callback.Container.IsEphemeral {
		if err := s.socket.Ack(*event.Request); err != nil {
			s.log.Warn("acknowledge private Slack dismissal", "error", err)
		}
		result, err := slackdismiss.HandleEphemeral(ctx, unpacedSlack(s.slack), callback.ResponseURL)
		if err != nil {
			s.log.Warn("delete private Slack message", "error", trimError(err))
			return
		}
		s.audit(ctx, result.Audit(input))
		return
	}
	if callback.Container.IsEphemeral && reportcanvas.NavigationAction(actionID) {
		if err := s.socket.Ack(*event.Request); err != nil {
			s.log.Warn("acknowledge private record navigation", "error", err)
		}
		message, err := reportcanvas.Navigate(ctx, s.store, s.slack, s.log, input)
		if err != nil {
			s.log.Warn("render private work record", "error", trimError(err))
			return
		}
		replacer, ok := unpacedSlack(s.slack).(interface {
			ReplaceResponse(context.Context, string, slackui.Message) error
		})
		if !ok {
			s.log.Warn("Slack client cannot replace a private work record")
			return
		}
		if err := replacer.ReplaceResponse(ctx, callback.ResponseURL, message); err != nil {
			s.log.Warn("replace private work record", "error", trimError(err))
		}
		return
	}
	if _, err := s.store.AdmitSlackInput(ctx, input); err != nil {
		s.log.Error("persist Slack interaction before acknowledgement",
			"envelope", input.EnvelopeID, "error", err)
		return
	}
	if err := s.socket.Ack(*event.Request); err != nil {
		s.log.Warn("acknowledge Slack interaction", "envelope", input.EnvelopeID, "error", err)
	}
}

func (s *Service) admitSlashCommand(ctx context.Context, event socketmode.Event) {
	if event.Request == nil {
		return
	}
	command, ok := event.Data.(slack.SlashCommand)
	if !ok {
		if pointer, pointerOK := event.Data.(*slack.SlashCommand); pointerOK && pointer != nil {
			command = *pointer
			ok = true
		}
	}
	if !ok || command.TeamID != s.cfg.Slack.TeamID ||
		command.Command != "/responder" ||
		command.ChannelID == "" ||
		command.UserID == "" {
		_ = s.socket.Ack(*event.Request)
		return
	}
	input := core.SlackInput{
		EnvelopeID: event.Request.EnvelopeID,
		EventID:    "slash:" + event.Request.EnvelopeID,
		Kind:       "slash",
		TeamID:     command.TeamID,
		ChannelID:  command.ChannelID,
		UserID:     command.UserID,
		Text:       command.Text,
		ActionID:   command.Command,
		ReceivedAt: s.now().UTC(),
	}
	if _, err := s.store.AdmitSlackInput(ctx, input); err != nil {
		s.log.Error(
			"persist Slack slash command before acknowledgement",
			"envelope", input.EnvelopeID,
			"error", err,
		)
		return
	}
	if err := s.socket.Ack(*event.Request); err != nil {
		s.log.Warn(
			"acknowledge Slack slash command",
			"envelope", input.EnvelopeID,
			"error", err,
		)
	}
}

func foreignSource(sourceTeam, localTeam string) bool {
	return sourceTeam != "" && sourceTeam != localTeam
}

func (s *Service) stripBotMention(text string) string {
	return strings.TrimSpace(strings.ReplaceAll(text, fmt.Sprintf("<@%s>", s.identity.BotUserID), ""))
}
