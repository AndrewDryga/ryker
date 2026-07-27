package service

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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
		EventID string `json:"event_id"`
	}
	_ = json.Unmarshal(event.Request.Payload, &wrapper)
	if wrapper.EventID == "" {
		wrapper.EventID = "envelope:" + envelopeID
	}
	input := core.SlackInput{
		EnvelopeID: envelopeID, EventID: wrapper.EventID, TeamID: outer.TeamID,
		ReceivedAt: time.Now().UTC(),
	}
	switch inner := outer.InnerEvent.Data.(type) {
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
		if inner == nil || inner.SubType != "" || inner.BotID != "" ||
			inner.User == "" || inner.User == s.identity.BotUserID ||
			inner.ThreadTimeStamp == "" || foreignSource(inner.SourceTeam, outer.TeamID) {
			_ = s.socket.Ack(*event.Request)
			return
		}
		input.Kind = "message"
		input.ChannelID = inner.Channel
		input.ThreadTS = inner.ThreadTimeStamp
		input.MessageTS = inner.TimeStamp
		input.UserID = inner.User
		input.Text = inner.Text
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
	if !ok || callback.Team.ID != s.cfg.Slack.TeamID || len(callback.ActionCallback.BlockActions) != 1 {
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

func foreignSource(sourceTeam, localTeam string) bool {
	return sourceTeam != "" && sourceTeam != localTeam
}

func (s *Service) stripBotMention(text string) string {
	return strings.TrimSpace(strings.ReplaceAll(text, fmt.Sprintf("<@%s>", s.identity.BotUserID), ""))
}
