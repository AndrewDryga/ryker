package service

import (
	"context"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/operatorchoice"
)

// handleOperatorChoice delegates the durable button semantics and keeps the
// service-owned effects here: the work timeline, audit trail, and Slack input
// receipt all use clients and policy owned by Service.
func (s *Service) handleOperatorChoice(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return err
	}
	if !allowed {
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.operator_choice", ActorID: input.UserID,
			ObjectID: input.ID, Outcome: "denied",
			Detail: "requester is not an active full workspace member",
		})
		return s.finishSlashInput(
			ctx, input,
			"*Only active workspace members can answer this question.*",
		)
	}
	result, err := operatorchoice.Handle(
		ctx, s.store, input, s.cfg.IsOperator(input.UserID), s.now().UTC(),
	)
	if err != nil {
		return err
	}
	if result.Timeline != nil {
		s.recordTimeline(ctx, *result.Timeline)
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "slack.operator_choice", ActorID: input.UserID,
		ObjectID: result.EpisodeID, Outcome: result.Outcome, Detail: result.Detail,
	})
	if result.Notice == "" {
		return s.finishSlackInput(ctx, input)
	}
	return s.finishSlashInput(ctx, input, result.Notice)
}
