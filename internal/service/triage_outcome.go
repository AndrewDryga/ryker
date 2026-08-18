package service

import (
	"context"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/triageoutcome"
)

func (s *Service) notifyRepositoryPreparationBlocked(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) error {
	if run.Mode != core.AgentRunTriage {
		return nil
	}
	var apiErr *coop.APIError
	if !errors.As(cause, &apiErr) || apiErr.Code != "repository_unavailable" {
		return nil
	}
	episode, err := s.store.GetWorkEpisode(ctx, run.EpisodeID)
	if err != nil {
		return err
	}
	if episode.Destination.ChannelID == "" {
		return nil
	}
	owner := core.FirstNonempty(run.EpisodeID, run.ID)
	body, err := slackui.Encode(s.sanitizeMessage(
		slackui.RepositoryPreparationBlocked(run.Repository, apiErr.Detail),
	))
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_preparation_blocked_" + owner, EpisodeID: run.EpisodeID,
		AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey,
		SourceInputID: run.SourceID, Operation: "post", Kind: "notice",
		ChannelID: episode.Destination.ChannelID, ThreadTS: episode.Destination.ThreadTS,
		ExpectedDestinationRevision: episode.DestinationRevision,
		Body:                        body,
		ResponseRoot:                false,
	})
	return err
}

func (s *Service) terminalTriageFailureDelivery(
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	message slackui.Message,
) (*core.SlackDelivery, error) {
	if !triageoutcome.NeedsFailureNotice(
		input, state, s.identity.BotUserID, s.identity.BotName,
	) {
		return nil, nil
	}
	channelID := core.FirstNonempty(input.ChannelID, run.ChannelID)
	threadTS := core.FirstNonempty(
		state.ResponseThreadTS, conversationalResponseThread(input), run.ThreadTS,
	)
	if channelID == "" {
		return nil, nil
	}
	body, err := slackui.Encode(s.sanitizeMessage(message))
	if err != nil {
		return nil, err
	}
	return &core.SlackDelivery{
		ID: executionDeliveryID("watch_failure_"+input.ID, run.IdempotencyKey), EpisodeID: run.EpisodeID,
		AgentRunID: run.ID, SourceInputID: input.ID, Operation: "post", Kind: "notice",
		ChannelID: channelID, ThreadTS: threadTS, Body: body, ResponseRoot: true,
	}, nil
}

func (s *Service) supersedeStaleHumanTriageResult(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
) (bool, error) {
	if !triageoutcome.NeedsFailureReply(input, state) {
		return false, nil
	}
	newer, err := s.store.HasNewerAgentRun(ctx, run, true)
	if err != nil || !newer {
		return false, err
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ActorID: input.UserID, ObjectID: input.ID,
		Outcome: "superseded",
		Detail:  "suppressed a stale answer because a newer human turn exists",
	})
	if err := s.store.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeSuperseded, "finished",
		"Superseded by a newer human turn", "", time.Time{},
	); err != nil {
		return false, err
	}
	return true, s.store.FinishAgentRun(ctx, run.ID)
}
