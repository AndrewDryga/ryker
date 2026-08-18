// Package incidentrun resolves the exact Coop session and authority generation
// an incident attempt may submit through.
package incidentrun

import (
	"context"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/fanout"
	"github.com/AndrewDryga/responder/internal/sessionauthority"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
)

type Sessions interface{ sessionauthority.Client }

type BranchSessions interface {
	Session(context.Context, core.AgentRun, core.Incident) (coop.Session, int, error)
}

type AuthorityStore interface {
	sessioncreate.IncidentSessionRotator
	AdvanceAgentRunGeneration(context.Context, string, int, time.Time) error
}

func ResolveSession(
	ctx context.Context,
	run core.AgentRun,
	incident core.Incident,
	sessions Sessions,
	branches BranchSessions,
	authority AuthorityStore,
	now time.Time,
) (coop.Session, int, bool, error) {
	generation := 0
	var session coop.Session
	var err error
	if fanout.IsBranch(run.ConversationKey) {
		session, generation, err = branches.Session(ctx, run, incident)
		if err != nil && generation > run.SessionGeneration {
			if generationErr := authority.AdvanceAgentRunGeneration(
				ctx, run.ID, generation, now,
			); generationErr != nil {
				err = errors.Join(err, generationErr)
			}
		}
	} else if incident.CoopSessionID == "" {
		// The binding can be rotated after this run leases. Rotation already
		// advanced the durable generation and returned the incident to
		// provisioning, so this attempt only has to yield without spending.
		return coop.Session{}, generation, true, nil
	} else {
		session, err = sessions.GetSession(ctx, incident.CoopSessionID)
		if sessioncreate.SessionNotFound(err) {
			rotated, rotateErr := authority.RotateReadOnly(
				ctx, incident.ID, incident.CoopSessionID,
				incident.CoopSessionGeneration,
				"bound Coop session no longer exists", now,
			)
			if rotateErr != nil {
				return coop.Session{}, generation, false, errors.Join(
					sessionauthority.ErrConvergence, err, rotateErr,
				)
			}
			return coop.Session{ID: incident.CoopSessionID}, generation, rotated, nil
		}
	}
	if err != nil {
		return coop.Session{}, generation, false, err
	}
	if sessioncreate.TerminalState(session.State) {
		rotated, rotateErr := authority.RotateReadOnly(
			ctx, incident.ID, session.ID, incident.CoopSessionGeneration,
			"bound Coop session became terminal before submission", now,
		)
		if rotateErr != nil {
			return session, generation, false, errors.Join(
				sessionauthority.ErrConvergence, rotateErr,
			)
		}
		return session, generation, rotated, nil
	}
	if fanout.IsBranch(run.ConversationKey) {
		return session, generation, false, nil
	}
	if !sessioncreate.ExactAuthority(incident, session) &&
		(session.ActiveTurnID != "" || session.QueuedTurnCount != 0) {
		latest, revoked, revokeErr := sessionauthority.Revoke(ctx, sessions, session)
		if revokeErr != nil {
			return coop.Session{}, generation, false, errors.Join(
				sessionauthority.ErrConvergence, revokeErr,
			)
		}
		session = latest
		if revoked {
			return session, generation, true, nil
		}
	}
	rotated, err := sessioncreate.RotateMismatchedIncidentAuthority(
		ctx, authority, incident, session, now,
	)
	if err != nil {
		return session, generation, false, errors.Join(
			sessionauthority.ErrConvergence, err,
		)
	}
	return session, generation, rotated, err
}

func RotationStatus(incident core.Incident, session coop.Session) string {
	if sessioncreate.TerminalState(session.State) {
		return "The terminal Coop session was retired before this turn could start; a replacement workspace is being prepared."
	}
	if session.ID == "" {
		return "The incident session binding changed before this turn could start; a replacement workspace is being prepared."
	}
	if incident.IsEngineeringTask() {
		return "The legacy read-only session was retired before this writable engineering turn could start."
	}
	return "The legacy writable session was retired before this read-only turn could start."
}
