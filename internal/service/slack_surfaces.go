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
	message := slackui.OperationsHome(
		metrics.IncidentsOpen,
		metrics.IncidentsTotal,
		metrics.SessionsOpen,
		len(failed),
		metrics.PublishedPRs,
		metrics.CleanupPending,
		metrics.CleanupBlocked,
		homeMemoryCount,
		incidents,
		memories,
	)
	if s.sanitizer != nil {
		message = s.sanitizer.Message(message)
	}
	return s.slack.PublishHome(ctx, userID, message)
}
