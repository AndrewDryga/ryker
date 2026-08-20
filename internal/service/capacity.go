package service

import (
	"context"
	"fmt"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/turncapacity"
)

func (s *Service) ensureTurnCapacity(
	ctx context.Context,
	channelID string,
	incidentID string,
	session coop.Session,
) (coop.Session, error) {
	if session.State != "exhausted" {
		return session, nil
	}
	limit, err := s.effectiveTurnLimit(ctx, channelID)
	if err != nil {
		return coop.Session{}, err
	}
	if session.MaxTurns >= limit {
		return coop.Session{}, &turncapacity.LimitError{Limit: limit}
	}
	additional := min(s.cfg.Coop.ExtendTurns, limit-session.MaxTurns)
	extended, _, err := s.coop.Extend(
		ctx,
		fmt.Sprintf("responder:auto-extend:%s:%d", session.ID, session.MaxTurns),
		session.ID,
		session.Revision,
		additional,
	)
	if err != nil {
		return coop.Session{}, err
	}
	if extended.MaxTurns <= session.MaxTurns || extended.State == "exhausted" {
		return coop.Session{}, fmt.Errorf(
			"Coop did not restore session capacity after adding %d turns",
			additional,
		)
	}
	s.audit(ctx, core.AuditEvent{
		IncidentID: incidentID,
		Kind:       "coop.budget.auto_extend",
		ActorID:    "responder",
		ObjectID:   session.ID,
		Outcome:    "succeeded",
		Detail: fmt.Sprintf(
			"automatic capacity %d -> %d; safety ceiling %d",
			session.MaxTurns, extended.MaxTurns, limit,
		),
	})
	return extended, nil
}
