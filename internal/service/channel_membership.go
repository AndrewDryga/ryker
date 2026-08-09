package service

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

type slackChannelLister interface {
	ListChannels(context.Context, string) ([]slackui.Channel, error)
}

// reportChannelCoverageGaps states which configured channels the bot cannot see.
//
// A channel can be configured with proactive participation and simultaneously
// have present = 0 in the membership table, and nothing anywhere treats that
// combination as wrong. It is not an error on either side: the operator's
// configuration is intact, the membership observation is accurate, and every
// alert posted in that room is silently invisible. C0TENANTAL1 was in this
// state for two days while the seven channels beside it were observed every
// minute, and the only way to learn it was to join the two tables by hand.
//
// The bot cannot fix this itself. Joining a public channel needs the
// channels:join scope, which deploy/slack-app-manifest.yaml does not request,
// so self-healing here would mean inventing a capability the app was not
// granted. What it can do is refuse to be quiet: the gap is logged when it
// appears and audited per channel, and the App Home carries it above
// everything else. Repeats are suppressed because this runs every minute and a
// warning printed 1,440 times a day is read as noise, which is its own kind of
// silence.
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
			Detail:   "invite the bot to this channel or remove its configuration",
		})
	}
}

func (s *Service) reconcileSlackChannelMemberships(ctx context.Context) error {
	lister, ok := s.slack.(slackChannelLister)
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
