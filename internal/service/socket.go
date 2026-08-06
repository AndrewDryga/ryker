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
	directChannelJoin := false
	if wrapper.EventTime > 0 {
		input.ReceivedAt = time.Unix(wrapper.EventTime, 0).UTC()
	}
	switch inner := outer.InnerEvent.Data.(type) {
	case *slackevents.AssistantThreadStartedEvent:
		// Surface refreshes are Slack writes, so they are admitted like any
		// other input and performed by the control lane. Doing them here would
		// hold the single socket consumer for a full Slack round trip and delay
		// admission of every event behind them.
		if inner == nil || inner.AssistantThread.UserID == "" ||
			inner.AssistantThread.ChannelID == "" || !s.cfg.Slack.AssistantExperience {
			_ = s.socket.Ack(*event.Request)
			return
		}
		input.Kind = inputSuggestedPrompts
		input.ChannelID = inner.AssistantThread.ChannelID
		input.ThreadTS = inner.AssistantThread.ThreadTimeStamp
		input.UserID = inner.AssistantThread.UserID
	case *slackevents.AppHomeOpenedEvent:
		if inner == nil || inner.User == "" {
			_ = s.socket.Ack(*event.Request)
			return
		}
		switch {
		case inner.Tab == "messages" &&
			s.cfg.Slack.AssistantExperience && inner.Channel != "":
			input.Kind = inputSuggestedPrompts
			input.ChannelID = inner.Channel
			input.UserID = inner.User
		case inner.Tab == "home":
			input.Kind = inputAppHome
			input.UserID = inner.User
		default:
			_ = s.socket.Ack(*event.Request)
			return
		}
	case *slackevents.ChannelDeletedEvent:
		if inner == nil {
			_ = s.socket.Ack(*event.Request)
			return
		}
		setLifecycleInput(&input, inner.Channel, "", core.ChannelDeleted, inner.Type)
	case *slackevents.GroupDeletedEvent:
		if inner == nil {
			_ = s.socket.Ack(*event.Request)
			return
		}
		setLifecycleInput(&input, inner.Channel, "", core.ChannelDeleted, inner.Type)
	case *slackevents.ChannelArchiveEvent:
		if inner == nil {
			_ = s.socket.Ack(*event.Request)
			return
		}
		setLifecycleInput(&input, inner.Channel, inner.User, core.ChannelArchived, inner.Type)
	case *slackevents.GroupArchiveEvent:
		if inner == nil {
			_ = s.socket.Ack(*event.Request)
			return
		}
		setLifecycleInput(&input, inner.Channel, "", core.ChannelArchived, inner.Type)
	case *slackevents.ChannelUnarchiveEvent:
		if inner == nil {
			_ = s.socket.Ack(*event.Request)
			return
		}
		setLifecycleInput(&input, inner.Channel, inner.User, core.ChannelActive, inner.Type)
	case *slackevents.GroupUnarchiveEvent:
		if inner == nil {
			_ = s.socket.Ack(*event.Request)
			return
		}
		setLifecycleInput(&input, inner.Channel, "", core.ChannelActive, inner.Type)
	case *slackevents.ReactionAddedEvent:
		if inner == nil {
			_ = s.socket.Ack(*event.Request)
			return
		}
		admit, err := s.setReactionInput(
			ctx, &input, "reaction_added", inner.User, inner.ItemUser,
			inner.Reaction, inner.Item, inner.EventTimestamp,
		)
		if err != nil {
			s.log.Error(
				"resolve Slack reaction target",
				"channel", inner.Item.Channel,
				"message", inner.Item.Timestamp,
				"error", err,
			)
			return
		}
		if !admit {
			_ = s.socket.Ack(*event.Request)
			return
		}
	case *slackevents.ReactionRemovedEvent:
		if inner == nil {
			_ = s.socket.Ack(*event.Request)
			return
		}
		admit, err := s.setReactionInput(
			ctx, &input, "reaction_removed", inner.User, inner.ItemUser,
			inner.Reaction, inner.Item, inner.EventTimestamp,
		)
		if err != nil {
			s.log.Error(
				"resolve Slack reaction target",
				"channel", inner.Item.Channel,
				"message", inner.Item.Timestamp,
				"error", err,
			)
			return
		}
		if !admit {
			_ = s.socket.Ack(*event.Request)
			return
		}
	case *slackevents.MemberJoinedChannelEvent:
		if inner == nil || inner.User != s.identity.BotUserID || inner.Channel == "" {
			_ = s.socket.Ack(*event.Request)
			return
		}
		input.Kind = "channel_joined"
		input.ChannelID = inner.Channel
		input.MessageTS = inner.EventTimestamp
		input.UserID = inner.Inviter
		directChannelJoin = true
	case *slackevents.AppMentionEvent:
		if inner == nil || inner.BotID != "" || foreignSource(inner.SourceTeam, outer.TeamID) {
			_ = s.socket.Ack(*event.Request)
			return
		}
		input.Kind = "mention"
		input.ChannelID = inner.Channel
		input.ThreadTS = inner.ThreadTimeStamp
		input.MessageTS = inner.TimeStamp
		input.UserID = inner.User
		input.Text = inner.Text
		input.Attachments = slackInputAttachments(inner.Files)
	case *slackevents.MessageEvent:
		if inner == nil || foreignSource(inner.SourceTeam, outer.TeamID) {
			_ = s.socket.Ack(*event.Request)
			return
		}
		message := normalizedSlackEventMessage(inner)
		if (message.SubType == slack.MsgSubTypeChannelJoin ||
			message.SubType == slack.MsgSubTypeGroupJoin) &&
			message.User == s.identity.BotUserID {
			input.Kind = "channel_joined"
			input.ChannelID = inner.Channel
			input.MessageTS = message.Timestamp
			input.UserID = message.Inviter
			directChannelJoin = true
			break
		}
		if s.identity.BotUserID != "" &&
			strings.Contains(message.Text, "<@"+s.identity.BotUserID+">") {
			// Slack also delivers this request as app_mention. Admit only that
			// event so one human message cannot consume two agent requests.
			_ = s.socket.Ack(*event.Request)
			return
		}
		ownBot := (s.identity.BotID != "" && message.BotID == s.identity.BotID) ||
			message.User == s.identity.BotUserID
		externalBot := message.BotID != "" || message.SubType == "bot_message"
		switch {
		case ownBot:
			_ = s.socket.Ack(*event.Request)
			return
		case externalBot:
			watched, err := s.proactiveEnabled(ctx, inner.Channel)
			if err != nil {
				s.log.Error(
					"resolve proactive Slack setting",
					"channel", inner.Channel,
					"error", err,
				)
				return
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
					return
				}
				watched = len(rules) > 0
			}
			if !watched || !supportedExternalMessageSubtype(inner.SubType) {
				_ = s.socket.Ack(*event.Request)
				return
			}
			input.Kind = "bot_message"
			input.UserID = firstNonempty(message.BotID, message.User)
		case humanMessageSubtype(inner.SubType) && message.User != "":
			input.Kind = "message"
			if strings.HasPrefix(inner.Channel, "D") {
				input.Kind = "direct"
			}
			input.UserID = message.User
		default:
			_ = s.socket.Ack(*event.Request)
			return
		}
		if input.UserID == "" {
			_ = s.socket.Ack(*event.Request)
			return
		}
		input.ChannelID = inner.Channel
		input.ThreadTS = message.ThreadTimestamp
		input.MessageTS = message.Timestamp
		input.Text = message.Text
		input.Attachments = slackInputAttachments(message.Files)
		if input.Kind == "message" {
			admit, err := s.shouldAdmitChannelMessage(ctx, input)
			if err != nil {
				s.log.Error(
					"decide whether to retain Slack channel message",
					"channel", input.ChannelID,
					"message", input.MessageTS,
					"error", err,
				)
				return
			}
			if !admit {
				_ = s.socket.Ack(*event.Request)
				return
			}
		}
	default:
		_ = s.socket.Ack(*event.Request)
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
	reaction, err := normalizeSlackReactionName(reaction)
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
		downloadURL := strings.TrimSpace(firstNonempty(file.URLPrivateDownload, file.URLPrivate))
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
	since := s.now().UTC().Add(-watchConversationContinuationWindow)
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
	input := core.SlackInput{
		EnvelopeID:  event.Request.EnvelopeID,
		EventID:     "interaction:" + event.Request.EnvelopeID,
		Kind:        "action",
		TeamID:      callback.Team.ID,
		ChannelID:   firstNonempty(callback.Container.ChannelID, callback.Channel.ID),
		ThreadTS:    firstNonempty(callback.Container.ThreadTs, callback.Message.ThreadTimestamp),
		MessageTS:   firstNonempty(callback.Container.MessageTs, callback.Message.Timestamp),
		UserID:      callback.User.ID,
		ActionID:    action.ActionID,
		ActionValue: action.Value,
		ReceivedAt:  s.now().UTC(),
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
