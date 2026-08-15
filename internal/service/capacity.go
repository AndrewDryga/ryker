package service

import (
	"context"
	"fmt"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

const turnLimitReachedPrefix = "Responder reached this channel's automatic safety ceiling"

type automaticTurnLimitError struct {
	Limit int
}

func (e *automaticTurnLimitError) Error() string {
	return fmt.Sprintf(
		"automatic turn ceiling %d reached; raise coop.turn_limit in responder.yaml to continue",
		e.Limit,
	)
}

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
		return coop.Session{}, &automaticTurnLimitError{Limit: limit}
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

func turnLimitReachedMessage(limit int) string {
	return fmt.Sprintf(
		turnLimitReachedPrefix+" of %d agent requests. "+
			"The pending request and Coop session are preserved. The ceiling is "+
			"`coop.turn_limit` in responder.yaml; raising it needs a deployment change, "+
			"because a session that has spent %d accepted requests is usually looping "+
			"rather than short of room. This counts accepted requests, not tool calls or "+
			"investigation steps within a request.",
		limit,
		limit,
	)
}
