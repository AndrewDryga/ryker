package service

import (
	"context"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

const turnLimitReachedPrefix = "Responder reached this channel's automatic safety ceiling"

type automaticTurnLimitError struct {
	Limit int
}

func (e *automaticTurnLimitError) Error() string {
	return fmt.Sprintf(
		"automatic turn ceiling %d reached; use /responder turn-limit with a higher value to continue",
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
			"The pending request and Coop session are preserved. An authorized operator can "+
			"raise it with `/responder turn-limit %d` or inspect the current policy with "+
			"`/responder turn-limit`. This ceiling counts accepted requests, not tool calls or "+
			"investigation steps within a request.",
		limit,
		min(limit+500, 10000),
	)
}

func (s *Service) resumeTurnLimitBlockedIncidents(
	ctx context.Context,
	scope string,
	channelID string,
) error {
	const pageSize = 100
	for offset := 0; ; offset += pageSize {
		incidents, total, err := s.store.ListIncidentPage(ctx, true, pageSize, offset)
		if err != nil {
			return err
		}
		for _, incident := range incidents {
			if scope == "channel" && incident.ChannelID != channelID {
				continue
			}
			if incident.Workflow != core.WorkflowBlocked ||
				!strings.HasPrefix(incident.LastError, turnLimitReachedPrefix) ||
				incident.CoopSessionID == "" {
				continue
			}
			session, err := s.coop.GetSession(ctx, incident.CoopSessionID)
			if err != nil {
				return err
			}
			limit, err := s.effectiveTurnLimit(ctx, incident.ChannelID)
			if err != nil {
				return err
			}
			if session.State == "closed" ||
				(session.State == "exhausted" && session.MaxTurns >= limit) {
				continue
			}
			if err := s.store.SetIncidentError(
				ctx, incident.ID, core.WorkflowParked, "",
			); err != nil {
				return err
			}
		}
		if offset+len(incidents) >= total {
			return nil
		}
	}
}
