package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	feedbackstore "github.com/AndrewDryga/responder/internal/feedback"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

var negativeFeedbackReactions = map[string]struct{}{
	"-1": {}, "thumbsdown": {}, "confused": {}, "disappointed": {},
	"face_with_raised_eyebrow": {}, "poop": {},
}

func feedbackID(parts ...string) string {
	digest := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return "fb_" + hex.EncodeToString(digest[:12])
}

func (s *Service) sanitizeFeedbackText(value string) string {
	if s.sanitizer == nil {
		return value
	}
	return s.sanitizer.Text(value)
}

func (s *Service) withFeedbackStore(fn func(*feedbackstore.Store) error) error {
	feedback, err := feedbackstore.Open(s.cfg.StateDir)
	if err != nil {
		return err
	}
	defer feedback.Close()
	return fn(feedback)
}

func (s *Service) recordReactionFeedback(ctx context.Context, input core.SlackInput) error {
	if _, negative := negativeFeedbackReactions[input.ActionID]; !negative {
		return nil
	}
	if _, err := s.store.GetSentSlackMessageDelivery(
		ctx, input.ChannelID, input.ActionValue,
	); errors.Is(err, store.ErrNotFound) {
		return nil
	} else if err != nil {
		return err
	}
	id := feedbackID("reaction", input.TeamID, input.ChannelID, input.ActionValue, input.UserID, input.ActionID)
	if input.Kind == "reaction_removed" {
		return s.withFeedbackStore(func(feedback *feedbackstore.Store) error {
			return feedback.Withdraw(ctx, id)
		})
	}
	contextMessages, err := s.feedbackContext(ctx, input, watchTurnState{}, input.ActionValue)
	if err != nil {
		return err
	}
	item := feedbackstore.Item{
		ID: id, WorkspaceID: input.TeamID, ChannelID: input.ChannelID,
		ThreadTS: input.ThreadTS, MessageTS: input.MessageTS,
		TargetMessageTS: input.ActionValue, UserID: input.UserID,
		Source: "negative_reaction", Category: "other", Sentiment: "negative",
		Summary: "User reacted negatively to a Responder message",
		Details: "Slack reaction: :" + input.ActionID + ":",
		Context: contextMessages, SourceRef: exactSlackMessageLink(input, input.ActionValue),
	}
	return s.withFeedbackStore(func(feedback *feedbackstore.Store) error {
		_, err := feedback.Record(ctx, item)
		return err
	})
}

func (s *Service) recordFeedbackOperations(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state watchTurnState,
	operations []investigation.ResultOperation,
) error {
	for _, operation := range operations {
		if operation.Type != "record_feedback" || operation.Feedback == nil {
			continue
		}
		value := operation.Feedback
		contextMessages, err := s.feedbackContext(ctx, input, state, value.TargetMessageTS)
		if err != nil {
			return err
		}
		item := feedbackstore.Item{
			ID:          feedbackID("model", input.TeamID, input.ID, operation.ID),
			WorkspaceID: input.TeamID, ChannelID: input.ChannelID,
			ThreadTS: input.ThreadTS, MessageTS: input.MessageTS,
			TargetMessageTS: value.TargetMessageTS, UserID: input.UserID,
			Source: "model_sentiment", Category: value.Category, Sentiment: value.Sentiment,
			Summary: truncateWatchText(strings.TrimSpace(s.sanitizeFeedbackText(value.Summary)), 500),
			Details: truncateWatchText(strings.TrimSpace(s.sanitizeFeedbackText(value.Details)), 4000),
			Context: contextMessages, EpisodeID: run.EpisodeID, AgentRunID: run.ID,
			SourceRef: exactSlackMessageLink(input, input.MessageTS),
		}
		if err := s.withFeedbackStore(func(feedback *feedbackstore.Store) error {
			_, err := feedback.Record(ctx, item)
			return err
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) recordExplicitFeedback(
	ctx context.Context,
	input core.SlackInput,
	text string,
) error {
	contextMessages, err := s.feedbackContext(ctx, input, watchTurnState{}, "")
	if err != nil {
		return err
	}
	item := feedbackstore.Item{
		ID:          feedbackID("explicit", input.TeamID, input.ID),
		WorkspaceID: input.TeamID, ChannelID: input.ChannelID,
		ThreadTS: input.ThreadTS, MessageTS: input.MessageTS, UserID: input.UserID,
		Source: "slash_command", Category: "other", Sentiment: "suggestion",
		Summary: truncateWatchText(strings.TrimSpace(s.sanitizeFeedbackText(text)), 500),
		Context: contextMessages, SourceRef: exactSlackMessageLink(input, input.MessageTS),
	}
	return s.withFeedbackStore(func(feedback *feedbackstore.Store) error {
		_, err := feedback.Record(ctx, item)
		return err
	})
}

func (s *Service) feedbackContext(
	ctx context.Context,
	input core.SlackInput,
	state watchTurnState,
	targetMessageTS string,
) ([]feedbackstore.ContextMessage, error) {
	messages := state.RecentMessages
	if len(messages) == 0 {
		targetTS := firstNonempty(targetMessageTS, input.MessageTS)
		history, historyErr := s.recentMessages(
			ctx, input.ChannelID, input.ThreadTS, targetTS, "", 20,
		)
		if historyErr == nil {
			messages = historyWatchContext(history, input.ChannelID, s.identity.BotUserID)
		} else {
			recent, err := s.store.ListRecentWatchMessages(ctx, input.ChannelID, 20)
			if err != nil {
				return nil, err
			}
			messages = make([]watchContextMessage, 0, len(recent)+1)
			for _, value := range recent {
				messages = append(messages, watchPromptMessage(value, s.identity.BotUserID, false))
			}
		}
	}
	result := make([]feedbackstore.ContextMessage, 0, len(messages)+1)
	for _, message := range messages {
		attachments := make([]feedbackstore.ContextAttachment, 0, len(message.Attachments))
		for _, attachment := range message.Attachments {
			attachments = append(attachments, feedbackstore.ContextAttachment{
				Name: attachment.Name, MediaType: attachment.MediaType, Size: attachment.Size,
			})
		}
		result = append(result, feedbackstore.ContextMessage{
			MessageTS: message.MessageTS, ThreadTS: message.ThreadTS,
			MessageLink: message.MessageLink, SenderID: message.SenderID,
			SenderType:  message.SenderType,
			Text:        truncateWatchText(strings.TrimSpace(s.sanitizeFeedbackText(message.Text)), 2000),
			Attachments: attachments,
		})
	}
	if targetMessageTS != "" {
		delivery, err := s.store.GetSentSlackMessageDelivery(ctx, input.ChannelID, targetMessageTS)
		if err == nil {
			var message slackui.Message
			if json.Unmarshal(delivery.Body, &message) == nil {
				text := firstNonempty(message.Markdown, strings.Join(message.Sections, "\n"), message.Text)
				result = append(result, feedbackstore.ContextMessage{
					MessageTS: targetMessageTS, ThreadTS: delivery.ThreadTS,
					SenderID: s.identity.BotUserID, SenderType: "responder",
					Text: truncateWatchText(strings.TrimSpace(s.sanitizeFeedbackText(text)), 3000),
				})
			}
		} else if !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
	}
	if len(result) > 30 {
		result = result[len(result)-30:]
	}
	return result, nil
}

func exactSlackMessageLink(input core.SlackInput, messageTS string) string {
	if strings.TrimSpace(input.ChannelID) == "" || strings.TrimSpace(messageTS) == "" {
		return ""
	}
	input.ThreadTS = ""
	input.MessageTS = messageTS
	return slackMessageLink(input)
}

func (s *Service) finishSlashFeedback(ctx context.Context, input core.SlackInput, text string) error {
	text = strings.TrimSpace(text)
	if text != "" {
		if err := s.recordExplicitFeedback(ctx, input, text); err != nil {
			return err
		}
		return s.finishSlashMessage(ctx, input, slackui.Notice(
			"Thanks. I saved that with the nearby conversation so the team can reproduce and improve it.",
		))
	}
	var items []feedbackstore.Item
	if err := s.withFeedbackStore(func(feedback *feedbackstore.Store) error {
		var err error
		items, err = feedback.ListOpen(ctx, s.cfg.Slack.TeamID, 20)
		return err
	}); err != nil {
		return err
	}
	if len(items) == 0 {
		return s.finishSlashMessage(ctx, input, slackui.Notice(
			"No open feedback yet. Use `/responder feedback <what should change>` to add one.",
		))
	}
	sections := make([]string, 0, len(items))
	for _, item := range items {
		line := fmt.Sprintf("*%s* · %s · <@%s>\n%s", item.Category, item.Source, item.UserID, item.Summary)
		if item.SourceRef != "" {
			line += "\n<" + item.SourceRef + "|Open context>"
		}
		sections = append(sections, line)
	}
	return s.finishSlashMessage(ctx, input, slackui.Message{
		Text: "Open Responder feedback", Header: "Open Responder feedback",
		Sections: sections,
		Context:  []string{"Showing the 20 newest open items. Context is stored in this workspace's local state."},
	})
}
