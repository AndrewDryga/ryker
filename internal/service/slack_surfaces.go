package service

import (
	"context"

	"github.com/AndrewDryga/responder/internal/slackui"
)

func (s *Service) publishOperationsHome(ctx context.Context, userID string) error {
	if !s.cfg.IsOperator(userID) {
		return s.slack.PublishHome(ctx, userID, slackui.OperationsHomeRestricted())
	}
	allowed, err := s.slack.UserAllowed(ctx, userID, s.cfg.Slack.TeamID)
	if err != nil {
		return err
	}
	if !allowed {
		return s.slack.PublishHome(ctx, userID, slackui.OperationsHomeRestricted())
	}
	metrics, err := s.store.Metrics(ctx)
	if err != nil {
		return err
	}
	incidents, _, err := s.store.ListIncidentPage(ctx, true, 8, 0)
	if err != nil {
		return err
	}
	failed, err := s.store.ListFailedWork(ctx, 100)
	if err != nil {
		return err
	}
	memories, err := s.store.ListMemoryForHome(
		ctx, s.cfg.Slack.TeamID, userID, 6,
	)
	if err != nil {
		return err
	}
	homeMemoryCount, err := s.store.CountMemoryForHome(
		ctx, s.cfg.Slack.TeamID, userID,
	)
	if err != nil {
		return err
	}
	preferences, err := s.store.ListPreferencesForHome(ctx, 3)
	if err != nil {
		return err
	}
	rules, err := s.store.ListStandingRulesForHome(ctx, 3)
	if err != nil {
		return err
	}
	commitments, err := s.store.ListActiveCommitments(ctx, 8)
	if err != nil {
		return err
	}
	commitmentCount, err := s.store.CountActiveCommitments(ctx)
	if err != nil {
		return err
	}
	situations, err := s.store.ListChannelSituations(ctx, 5)
	if err != nil {
		return err
	}
	message := slackui.OperationsHome(
		metrics.IncidentsOpen,
		metrics.IncidentsTotal,
		metrics.SessionsOpen,
		len(failed),
		metrics.PublishedPRs,
		metrics.CleanupPending,
		metrics.CleanupBlocked,
		homeMemoryCount,
		metrics.PreferencesActive,
		metrics.RulesActive,
		metrics.SchedulesActive,
		commitmentCount,
		incidents,
		commitments,
		situations,
		memories,
		preferences,
		rules,
	)
	message = s.sanitizeMessage(message)
	return s.slack.PublishHome(ctx, userID, message)
}
