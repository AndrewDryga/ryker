package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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
		ReceivedAt: time.Now().UTC(),
	}
	if wrapper.EventTime > 0 {
		input.ReceivedAt = time.Unix(wrapper.EventTime, 0).UTC()
	}
	switch inner := outer.InnerEvent.Data.(type) {
	case *slackevents.AssistantThreadStartedEvent:
		if inner == nil || inner.AssistantThread.UserID == "" ||
			inner.AssistantThread.ChannelID == "" {
			_ = s.socket.Ack(*event.Request)
			return
		}
		_ = s.socket.Ack(*event.Request)
		if s.cfg.Slack.AssistantExperience {
			if err := s.slack.SetSuggestedPrompts(
				ctx,
				inner.AssistantThread.ChannelID,
				inner.AssistantThread.ThreadTimeStamp,
			); err != nil {
				s.log.Warn(
					"set Slack assistant suggested prompts",
					"channel", inner.AssistantThread.ChannelID,
					"error", err,
				)
			}
		}
		return
	case *slackevents.AppHomeOpenedEvent:
		if inner == nil || inner.User == "" {
			_ = s.socket.Ack(*event.Request)
			return
		}
		_ = s.socket.Ack(*event.Request)
		switch inner.Tab {
		case "messages":
			if s.cfg.Slack.AssistantExperience && inner.Channel != "" {
				if err := s.slack.SetSuggestedPrompts(ctx, inner.Channel, ""); err != nil {
					s.log.Warn(
						"set Slack agent suggested prompts",
						"channel", inner.Channel,
						"error", err,
					)
				}
			}
		case "home":
			if err := s.publishOperationsHome(ctx, inner.User); err != nil {
				s.log.Warn("publish Slack App Home", "user", inner.User, "error", err)
			}
		}
		return
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
	case *slackevents.MessageEvent:
		if inner == nil || foreignSource(inner.SourceTeam, outer.TeamID) {
			_ = s.socket.Ack(*event.Request)
			return
		}
		if s.identity.BotUserID != "" &&
			strings.Contains(inner.Text, "<@"+s.identity.BotUserID+">") {
			// Slack also delivers this request as app_mention. Admit only that
			// event so one human message cannot consume two agent requests.
			_ = s.socket.Ack(*event.Request)
			return
		}
		ownBot := (s.identity.BotID != "" && inner.BotID == s.identity.BotID) ||
			inner.User == s.identity.BotUserID
		externalBot := inner.BotID != "" || inner.SubType == "bot_message"
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
					Text:      inner.Text,
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
			if !watched || (inner.SubType != "" && inner.SubType != "bot_message") {
				_ = s.socket.Ack(*event.Request)
				return
			}
			input.Kind = "bot_message"
			input.UserID = firstNonempty(inner.BotID, inner.User)
		case inner.SubType == "" && inner.User != "":
			input.Kind = "message"
			if strings.HasPrefix(inner.Channel, "D") {
				input.Kind = "direct"
			}
			input.UserID = inner.User
		default:
			_ = s.socket.Ack(*event.Request)
			return
		}
		if input.UserID == "" {
			_ = s.socket.Ack(*event.Request)
			return
		}
		input.ChannelID = inner.Channel
		input.ThreadTS = inner.ThreadTimeStamp
		input.MessageTS = inner.TimeStamp
		input.Text = inner.Text
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
	if _, err := s.store.AdmitSlackInput(ctx, input); err != nil {
		s.log.Error("persist Slack event before acknowledgement", "envelope", envelopeID, "error", err)
		return
	}
	if err := s.socket.Ack(*event.Request); err != nil {
		s.log.Warn("acknowledge Slack event", "envelope", envelopeID, "error", err)
	}
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
	since := time.Now().UTC().Add(-watchConversationContinuationWindow)
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
			ActionID:    callback.CallbackID,
			ActionValue: callback.Message.User,
			ReceivedAt:  time.Now().UTC(),
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
		ReceivedAt:  time.Now().UTC(),
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
		ReceivedAt: time.Now().UTC(),
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
