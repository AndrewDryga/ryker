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
	memories, err := s.store.Memory.ListMemoryForHome(
		ctx, s.cfg.Slack.TeamID, userID, 6,
	)
	if err != nil {
		return err
	}
	homeMemoryCount, err := s.store.Memory.CountMemoryForHome(
		ctx, s.cfg.Slack.TeamID, userID,
	)
	if err != nil {
		return err
	}
	preferences, err := s.store.Behavior.ListPreferencesForHome(ctx, 3)
	if err != nil {
		return err
	}
	rules, err := s.store.Behavior.ListStandingRulesForHome(ctx, 3)
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
	situations, err := s.store.Intelligence.ListChannelSituations(ctx, 5)
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
	// A configured channel the bot cannot see is a coverage hole, and the page
	// that answers "does anything need me now" is where it belongs. A read
	// failure here must not cost the operator the rest of the page, but it also
	// must not pass as "no gaps" — the same could-not-run-reported-as-nothing-
	// found defect this repository keeps finding.
	if gaps, err := s.store.ListConfiguredChannelsMissingMembership(ctx, 25); err != nil {
		s.log.Warn("read configured channels without membership for App Home", "error", err)
	} else {
		message = slackui.AppendCoverageGaps(message, gaps)
	}
	if feedback, err := s.openFeedbackSummaries(ctx); err != nil {
		// The dashboard is still worth publishing without this section.
		s.log.Warn("read open feedback for App Home", "error", err)
	} else {
		message = slackui.AppendFeedbackDigest(message, feedback)
		candidates, candidatesErr := s.pendingFixtureReview(ctx)
		if candidatesErr != nil {
			return candidatesErr
		}
		message = slackui.AppendFixtureReview(message, candidates)
	}
	message = s.sanitizeMessage(message)
	return s.slack.PublishHome(ctx, userID, message)
}
