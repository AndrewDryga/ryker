package service

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func CancelSlackReplay(
	ctx context.Context,
	s *Service,
	replayID string,
	expectedRunKey string,
	actor string,
) error {
	return s.replayControl.Cancel(ctx, replayID, expectedRunKey, actor)
}

func (s *Service) agentRunCancellationApplied(ctx context.Context, runID string) bool {
	checkCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
	defer cancel()
	run, err := s.store.GetAgentRun(checkCtx, runID)
	return err == nil && run.State == core.AgentRunCancelled
}

func (s *Service) processReplayCancellation(ctx context.Context) error {
	pending, err := s.store.ReplayCancellations.Next(ctx)
	if err != nil {
		return err
	}
	return s.replayControl.Interrupt(ctx, core.AgentRun{
		ID: pending.RunID, IdempotencyKey: pending.RunKey,
		SessionID: pending.SessionID, CoopTurnID: pending.TurnID,
	}, s.now().Sub(pending.CreatedAt) >= 2*time.Minute)
}
