package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// catchUpSlackAppMessages closes the bounded delivery gap left by Socket Mode,
// which does not replay events emitted while Responder is disconnected. Only
// external-app messages are recovered; human conversation is never replayed.
func (s *Service) catchUpSlackAppMessages(ctx context.Context) error {
	window := s.cfg.Slack.StartupHistoryWindow.Duration
	if window <= 0 {
		return nil
	}
	channelIDs, err := s.store.ListPresentSlackChannelIDs(ctx, 10000)
	if err != nil {
		return err
	}
	channelIDs = append(channelIDs, s.cfg.Slack.WatchChannels...)
	channelIDs = append(channelIDs, s.cfg.Slack.ShadowChannels...)
	slices.Sort(channelIDs)
	channelIDs = slices.Compact(channelIDs)

	since := time.Now().UTC().Add(-window)
	sinceTS := fmt.Sprintf("%d.000000", since.Unix())
	recovered := 0
	for _, channelID := range channelIDs {
		proactive, proactiveErr := s.proactiveEnabled(ctx, channelID)
		if proactiveErr != nil {
			return proactiveErr
		}
		shadow, shadowErr := s.shadowEnabled(ctx, channelID)
		if shadowErr != nil {
			return shadowErr
		}
		rules, rulesErr := s.store.ListStandingRulesForChannel(ctx, channelID, true, 100)
		if rulesErr != nil {
			return rulesErr
		}
		appRules := false
		for _, rule := range rules {
			if standingRuleSourceMatches(rule.SourceKind, "bot_message") {
				appRules = true
				break
			}
		}
		if !proactive && !shadow && !appRules {
			continue
		}

		history, historyErr := s.slack.RecentMessages(
			ctx, channelID, "", "", sinceTS, 100,
		)
		if historyErr != nil {
			s.log.Warn(
				"skip Slack startup history catch-up",
				"channel", channelID,
				"error", historyErr,
			)
			continue
		}
		slices.SortFunc(history, func(left, right slackui.HistoryMessage) int {
			return strings.Compare(left.Timestamp, right.Timestamp)
		})
		for _, message := range history {
			if message.BotID == "" || message.Timestamp == "" ||
				message.BotID == s.identity.BotID || message.UserID == s.identity.BotUserID {
				continue
			}
			input := slackHistoryAppInput(s.cfg.Slack.TeamID, channelID, message)
			if appRules && !proactive && !shadow {
				matched := false
				for _, rule := range rules {
					if standingRuleSourceMatches(rule.SourceKind, input.Kind) &&
						standingRuleTextMatches(rule.Trigger, input.Text) {
						matched = true
						break
					}
				}
				if !matched {
					continue
				}
			}
			if _, existingErr := s.store.GetSlackInputForMessage(
				ctx, channelID, message.Timestamp,
			); existingErr == nil {
				continue
			} else if !errors.Is(existingErr, store.ErrNotFound) {
				return existingErr
			}
			created, admitErr := s.store.AdmitSlackInput(ctx, input)
			if admitErr != nil {
				return admitErr
			}
			if created {
				recovered++
			}
		}
	}
	if recovered > 0 {
		s.log.Info("recovered missed Slack app messages", "count", recovered)
	}
	return nil
}

func slackHistoryAppInput(
	teamID string,
	channelID string,
	message slackui.HistoryMessage,
) core.SlackInput {
	attachments := make([]core.SlackAttachment, 0, len(message.Files))
	for _, file := range message.Files {
		attachments = append(attachments, core.SlackAttachment{
			ID: file.ID, Name: file.Name, MediaType: file.MediaType,
			Size: file.Size, URLPrivate: file.URLPrivate,
		})
	}
	input := core.SlackInput{
		EnvelopeID:  "history:" + channelID + ":" + message.Timestamp,
		EventID:     "history:" + channelID + ":" + message.Timestamp,
		Kind:        "bot_message",
		TeamID:      teamID,
		ChannelID:   channelID,
		ThreadTS:    message.ThreadTS,
		MessageTS:   message.Timestamp,
		UserID:      firstNonempty(message.BotID, message.UserID),
		Text:        message.Text,
		Attachments: attachments,
		Reactions:   coreSlackReactions(message.Reactions),
		ReceivedAt:  slackMessageTime(message.Timestamp),
	}
	bindCanonicalSlackMessageInputID(&input)
	return input
}

func slackMessageTime(timestamp string) time.Time {
	seconds, err := strconv.ParseFloat(timestamp, 64)
	if err != nil || seconds <= 0 {
		return time.Now().UTC()
	}
	whole := int64(seconds)
	nanos := int64((seconds - float64(whole)) * float64(time.Second))
	return time.Unix(whole, nanos).UTC()
}
