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
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
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
		return s.store.WithdrawFeedback(ctx, id)
	}
	contextMessages, err := s.feedbackContext(ctx, input, decisionpkg.WatchTurnState{}, input.ActionValue)
	if err != nil {
		return err
	}
	item := store.FeedbackItem{
		ID: id, WorkspaceID: input.TeamID, ChannelID: input.ChannelID,
		ThreadTS: input.ThreadTS, MessageTS: input.MessageTS,
		TargetMessageTS: input.ActionValue, UserID: input.UserID,
		Source: "negative_reaction", Category: "other", Sentiment: "negative",
		Summary: "User reacted negatively to a Responder message",
		Details: "Slack reaction: :" + input.ActionID + ":",
		Context: contextMessages, SourceRef: exactSlackMessageLink(input, input.ActionValue),
	}
	if _, err := s.store.RecordFeedback(ctx, item); err != nil {
		return err
	}
	return nil
}

func (s *Service) recordFeedbackOperations(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
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
		item := store.FeedbackItem{
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
		if _, err := s.store.RecordFeedback(ctx, item); err != nil {
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
	contextMessages, err := s.feedbackContext(ctx, input, decisionpkg.WatchTurnState{}, "")
	if err != nil {
		return err
	}
	item := store.FeedbackItem{
		ID:          feedbackID("explicit", input.TeamID, input.ID),
		WorkspaceID: input.TeamID, ChannelID: input.ChannelID,
		ThreadTS: input.ThreadTS, MessageTS: input.MessageTS, UserID: input.UserID,
		Source: "slash_command", Category: "other", Sentiment: "suggestion",
		Summary: truncateWatchText(strings.TrimSpace(s.sanitizeFeedbackText(text)), 500),
		Context: contextMessages, SourceRef: exactSlackMessageLink(input, input.MessageTS),
	}
	if _, err := s.store.RecordFeedback(ctx, item); err != nil {
		return err
	}
	return nil
}

func (s *Service) feedbackContext(
	ctx context.Context,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	targetMessageTS string,
) ([]store.FeedbackContextMessage, error) {
	messages := state.RecentMessages
	if len(messages) == 0 {
		targetTS := core.FirstNonempty(targetMessageTS, input.MessageTS)
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
			messages = make([]decisionpkg.WatchContextMessage, 0, len(recent)+1)
			for _, value := range recent {
				messages = append(messages, watchPromptMessage(value, s.identity.BotUserID, false))
			}
		}
	}
	result := make([]store.FeedbackContextMessage, 0, len(messages)+1)
	for _, message := range messages {
		attachments := make([]store.FeedbackContextAttachment, 0, len(message.Attachments))
		for _, attachment := range message.Attachments {
			attachments = append(attachments, store.FeedbackContextAttachment{
				Name: attachment.Name, MediaType: attachment.MediaType, Size: attachment.Size,
			})
		}
		result = append(result, store.FeedbackContextMessage{
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
				text := core.FirstNonempty(message.Markdown, strings.Join(message.Sections, "\n"), message.Text)
				result = append(result, store.FeedbackContextMessage{
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
	items, err := s.store.ListOpenFeedback(ctx, s.cfg.Slack.TeamID, 20)
	if err != nil {
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

// openFeedbackSummaries lists product feedback still awaiting an operator
// decision, for the App Home digest.
func (s *Service) openFeedbackSummaries(ctx context.Context) ([]slackui.FeedbackSummary, error) {
	items, err := s.store.ListOpenFeedback(ctx, s.cfg.Slack.TeamID, 20)
	if err != nil {
		return nil, err
	}
	result := make([]slackui.FeedbackSummary, 0, len(items))
	for _, item := range items {
		result = append(result, slackui.FeedbackSummary{
			ID: item.ID, Category: item.Category, Sentiment: item.Sentiment,
			Summary: item.Summary, SourceRef: item.SourceRef,
		})
	}
	return result, nil
}

// handleDismissFeedback records that an operator read a feedback item and chose
// not to act on it. Dismissing is a real outcome — the alternative is a queue
// that only grows, which teaches everyone to ignore it.
func (s *Service) handleDismissFeedback(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	err = s.store.ResolveFeedback(ctx, input.ActionValue, "dismissed", input.UserID)
	if errors.Is(err, store.ErrFeedbackNotOpen) {
		return s.memoryActionFeedback(
			ctx, input, "*That feedback was already resolved.* Nothing changed.",
		)
	}
	if err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		ID: "audit_feedback_dismiss_" + input.ID, Kind: "feedback.dismiss",
		ActorID: input.UserID, ObjectID: input.ActionValue, Outcome: "dismissed",
	})
	return s.refreshHomeAfterFeedback(ctx, input)
}

// handleConvertFeedback turns a feedback item into durable guidance.
//
// The conversion reuses the ordinary guidance confirmation card, so the
// operator sees and approves the exact wording before anything is stored. The
// model never gains a path to write its own instructions — feedback it recorded
// becomes behaviour only when a person says so.
// handleConvertFeedbackToBriefer turns tone feedback into a typed
// response_detail preference.
//
// The difference from handleConvertFeedback is enforcement. Guidance is
// context the model weighs and may reasonably set aside; a preference is a
// rule the host applies. Someone who has said "be more concise" three times is
// not asking to be weighed.
//
// The value is fixed by which button was pressed rather than read out of the
// feedback text. "Be more concise" and "that was too terse" are both tone, and
// inferring the direction from prose is how an agent ends up confidently doing
// the opposite of what was asked.
func (s *Service) handleConvertFeedbackToBriefer(
	ctx context.Context,
	input core.SlackInput,
) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	item, err := s.store.GetFeedback(ctx, input.ActionValue)
	if err != nil {
		return s.memoryActionFeedback(
			ctx, input, "*That feedback is no longer available.* Nothing changed.",
		)
	}
	if item.Status != "open" {
		return s.memoryActionFeedback(
			ctx, input, "*That feedback was already resolved.* Nothing changed.",
		)
	}
	preference, _, err := s.preferenceFromOffer(input, core.PreferenceOffer{
		Scope: "workspace", Name: "response_detail", Value: "brief",
	}, s.now().UTC())
	if err != nil {
		return s.memoryActionFeedback(
			ctx, input,
			"*I could not set that preference.* "+err.Error()+" Nothing changed.",
		)
	}
	preference.SourceRef = "feedback:" + item.ID
	saved, _, err := s.store.UpsertPreference(
		ctx, preference, s.cfg.Limits.MaxPreferences, s.cfg.Limits.MaxPreferencesPerScope,
	)
	if err != nil {
		return err
	}
	if err = s.store.ResolveFeedback(
		ctx, item.ID, "converted", input.UserID,
	); err != nil && !errors.Is(err, store.ErrFeedbackNotOpen) {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		ID: "audit_feedback_preference_" + input.ID, Kind: "feedback.convert",
		ActorID: input.UserID, ObjectID: item.ID, Outcome: "preference",
		Detail: "preference=" + saved.ID,
	})
	return s.refreshHomeAfterFeedback(ctx, input)
}

func (s *Service) handleConvertFeedback(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	item, err := s.store.GetFeedback(ctx, input.ActionValue)
	if err != nil {
		return s.memoryActionFeedback(
			ctx, input, "*That feedback is no longer available.* Nothing changed.",
		)
	}
	if item.Status != "open" {
		return s.memoryActionFeedback(
			ctx, input, "*That feedback was already resolved.* Nothing changed.",
		)
	}
	entry := core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: s.cfg.Slack.TeamID,
		SubjectKey:     memorypkg.NormalizeGuidanceSubject(item.Category),
		Predicate:      "guidance",
		Value:          core.BoundedText(item.Summary, 1000),
		VisibilityKind: "workspace", VisibilityID: s.cfg.Slack.TeamID,
		ExpiresAt: s.now().UTC().Add(memorypkg.DefaultTTL),
		SourceRef: "feedback:" + item.ID,
		ActorID:   input.UserID,
	}
	if err := s.validateMemoryValue(&entry); err != nil {
		return s.memoryActionFeedback(
			ctx, input,
			"*This feedback cannot become guidance as written.* "+err.Error()+
				" Ask Responder to remember the behaviour you want in your own words instead.",
		)
	}
	saved, _, err := s.store.UpsertMemoryEntry(
		ctx, entry, s.cfg.Limits.MaxMemoryEntries, s.cfg.Limits.MaxMemoryEntriesPerScope,
	)
	if err != nil {
		return err
	}
	if err = s.store.ResolveFeedback(ctx, item.ID, "converted", input.UserID); err != nil && !errors.Is(err, store.ErrFeedbackNotOpen) {
		return err
	}
	s.audit(ctx, core.AuditEvent{
		ID: "audit_feedback_convert_" + input.ID, Kind: "feedback.convert",
		ActorID: input.UserID, ObjectID: item.ID, Outcome: "converted",
		Detail: "memory=" + saved.ID,
	})
	return s.refreshHomeAfterFeedback(ctx, input)
}

func (s *Service) refreshHomeAfterFeedback(ctx context.Context, input core.SlackInput) error {
	if input.ChannelID == "" {
		if err := s.publishOperationsHome(ctx, input.UserID); err != nil {
			return err
		}
		return s.finishSlackInput(ctx, input)
	}
	return s.finishSlashInput(ctx, input, "*Feedback resolved.*")
}
