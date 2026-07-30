package service

import (
	"context"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

type slackChannelLister interface {
	ListChannels(context.Context, string) ([]slackui.Channel, error)
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
	now := time.Now().UTC()
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
		_ = s.store.Audit(ctx, core.AuditEvent{
			Kind: "slack.channel.membership", ObjectID: item.ChannelID,
			Outcome: "onboarding_queued", Detail: item.ChannelName,
		})
	}
	return nil
}
