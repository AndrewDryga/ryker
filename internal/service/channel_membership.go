package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

type slackChannelLister interface {
	ListChannels(context.Context, string) ([]slackui.Channel, error)
}

// reportChannelCoverageGaps states which configured channels the bot cannot see,
// and closes the ones it is allowed to close.
//
// A channel can be configured with proactive participation and simultaneously
// have present = 0 in the membership table, and nothing anywhere treats that
// combination as wrong. It is not an error on either side: the operator's
// configuration is intact, the membership observation is accurate, and every
// alert posted in that room is silently invisible. C091FK0HHAQ was in this
// state for two days while the seven channels beside it were observed every
// minute, and the only way to learn it was to join the two tables by hand.
//
// Reporting was the first half of the answer and self-healing is the second:
// deploy/slack-app-manifest.yaml now requests channels:join, so a public
// channel can be entered without a person. A private one still cannot, by
// Slack's design, and the difference has to be stated rather than retried.
// Repeats are suppressed because this runs every minute — a warning printed
// 1,440 times a day is read as noise, which is its own kind of silence, and
// re-asking Slack to join a room it has already refused is the same waste in
// API calls. Both the report and the attempt therefore happen when the set of
// gaps changes, which includes the first pass after a restart.
func (s *Service) reportChannelCoverageGaps(ctx context.Context) {
	gaps, err := s.store.ListConfiguredChannelsMissingMembership(ctx, 100)
	if err != nil {
		if ctx.Err() == nil {
			s.log.Warn("could not check configured channels for missing membership", "error", err)
		}
		return
	}
	slices.Sort(gaps)
	fingerprint := strings.Join(gaps, ",")
	s.coverageGapsMu.Lock()
	unchanged := fingerprint == s.reportedCoverageGaps
	s.reportedCoverageGaps = fingerprint
	s.coverageGapsMu.Unlock()
	if unchanged || len(gaps) == 0 {
		return
	}
	s.log.Warn(
		"configured channels are not joined, so nothing posted in them is seen",
		"channels", strings.Join(gaps, " "),
		"count", len(gaps),
	)
	for _, channelID := range gaps {
		s.audit(ctx, core.AuditEvent{
			Kind:     "slack.channel.coverage",
			ObjectID: channelID,
			Outcome:  "configured_not_joined",
			Detail:   "nothing posted in this channel is seen while the bot is absent",
		})
		s.joinConfiguredChannel(ctx, channelID)
	}
}

// joinConfiguredChannel tries to enter one configured channel the bot is absent
// from, and records which of the several different things happened.
//
// "The join failed" is not a usable report, because the repairs differ: a
// private channel needs a person to run /invite and will never yield to a
// retry, an archived one needs unarchiving first, a channel Slack will not
// describe is probably a stale configuration row, and a missing_scope refusal
// means this binary is newer than the installation it is running against.
// Every one of those is audited under its own outcome so the answer to "why is
// Ryker still not in that room" is a row rather than an investigation.
func (s *Service) joinConfiguredChannel(ctx context.Context, channelID string) {
	channel, err := s.slack.GetChannel(ctx, channelID)
	switch {
	case errors.Is(err, slackui.ErrNotFound):
		s.recordJoinAttempt(ctx, channelID, "channel_not_found",
			"Slack does not show this channel to the bot; the configuration may name a deleted channel")
		return
	case err != nil:
		s.log.Warn("inspect configured channel before joining", "channel", channelID, "error", err)
		s.recordJoinAttempt(ctx, channelID, "unknown", trimError(err))
		return
	case channel.Member:
		// The membership table is a minute stale at worst; the next
		// reconciliation clears the gap on its own.
		return
	case channel.Archived:
		s.recordJoinAttempt(ctx, channelID, "archived",
			"the channel is archived; unarchive it or remove its configuration")
		return
	case channel.Private:
		s.recordJoinAttempt(ctx, channelID, "private_needs_invite",
			"conversations.join cannot add an app to a private channel; run /invite for the bot there")
		return
	}
	if joinErr := s.slack.JoinChannel(ctx, channelID); joinErr != nil {
		if slackui.MissingScope(joinErr) {
			s.recordJoinAttempt(ctx, channelID, "missing_scope",
				"this build asks for channels:join but the installed app does not grant it; "+
					"reinstall the app from deploy/slack-app-manifest.yaml or invite the bot manually")
			return
		}
		s.recordJoinAttempt(ctx, channelID, "failed", trimError(joinErr))
		return
	}
	s.recordJoinAttempt(ctx, channelID, "joined", channel.Name)
}

func (s *Service) recordJoinAttempt(ctx context.Context, channelID, outcome, detail string) {
	if outcome == "joined" {
		s.log.Info("joined a configured channel the bot was missing from",
			"channel", channelID, "name", detail)
	} else {
		s.log.Warn("could not join a configured channel",
			"channel", channelID, "outcome", outcome, "reason", detail)
	}
	s.audit(ctx, core.AuditEvent{
		Kind:     "slack.channel.join",
		ObjectID: channelID,
		Outcome:  outcome,
		Detail:   detail,
	})
}

func (s *Service) reconcileSlackChannelMemberships(ctx context.Context) error {
	lister, ok := unpacedSlack(s.slack).(slackChannelLister)
	if !ok {
		return store.ErrNotFound
	}
	channels, err := lister.ListChannels(ctx, s.cfg.Slack.TeamID)
	if err != nil {
		return fmt.Errorf("list Slack channels: %w", err)
	}
	now := s.now().UTC()
	observations := make([]store.SlackChannelMembershipObservation, 0, len(channels))
	for _, channel := range channels {
		observations = append(observations, store.SlackChannelMembershipObservation{
			ChannelID: channel.ID, ChannelName: channel.Name, Private: channel.Private,
			Present: channel.Member && !channel.Archived,
		})
	}
	if err := s.store.ReconcileSlackChannelMemberships(ctx, observations, now); err != nil {
		return fmt.Errorf("reconcile Slack channel membership: %w", err)
	}
	s.reportChannelCoverageGaps(ctx)
	pending, err := s.store.ListPendingSlackChannelOnboarding(ctx, 100)
	if err != nil {
		return err
	}
	if len(pending) == 0 {
		return store.ErrNotFound
	}
	for _, item := range pending {
		incidentChannel, err := s.store.IsIncidentChannel(ctx, item.ChannelID)
		if err != nil {
			return err
		}
		if incidentChannel {
			if err := s.store.FinishSlackChannelOnboarding(
				ctx, item.ChannelID, item.JoinedAt,
			); err != nil {
				return err
			}
			continue
		}
		key := item.ChannelID + ":" + item.JoinedAt.Format(time.RFC3339Nano)
		_, err = s.store.AdmitSlackInput(ctx, core.SlackInput{
			ID: "slack_channel_membership:" + key, EnvelopeID: "membership:" + key,
			EventID: "membership:" + key, Kind: "channel_joined",
			TeamID: s.cfg.Slack.TeamID, ChannelID: item.ChannelID,
			ReceivedAt: item.JoinedAt,
		})
		if err != nil {
			return err
		}
		if err := s.store.FinishSlackChannelOnboarding(
			ctx, item.ChannelID, item.JoinedAt,
		); err != nil {
			return err
		}
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.channel.membership", ObjectID: item.ChannelID,
			Outcome: "onboarding_queued", Detail: item.ChannelName,
		})
	}
	return nil
}
