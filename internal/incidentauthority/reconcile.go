// Package incidentauthority reconciles ordinary incident sessions with their
// current read-only repository authority.
package incidentauthority

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/sessionauthority"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
)

type Store interface {
	UpdateCoopState(context.Context, string, int64, int64, string, core.WorkflowState) error
	CloseIncident(context.Context, string) error
}

func Reconcile(
	ctx context.Context,
	client sessionauthority.Client,
	store Store,
	rotator sessioncreate.IncidentSessionRotator,
	incident core.Incident,
	session coop.Session,
	eventCursor int64,
	now time.Time,
) (bool, error) {
	if sessioncreate.TerminalState(session.State) {
		if !incident.ChannelWritable() {
			return true, store.UpdateCoopState(
				ctx, incident.ID, session.Revision, eventCursor, "", core.WorkflowBlocked,
			)
		}
		if incident.Status != core.IncidentClosed {
			return true, store.CloseIncident(ctx, incident.ID)
		}
		return true, store.UpdateCoopState(
			ctx, incident.ID, session.Revision, eventCursor, "", core.WorkflowClosed,
		)
	}
	if !sessioncreate.ExactAuthority(incident, session) &&
		(session.ActiveTurnID != "" || session.QueuedTurnCount != 0) {
		_, revoked, err := sessionauthority.Revoke(ctx, client, session)
		if err != nil || revoked {
			return true, err
		}
	}
	rotated, err := sessioncreate.RotateMismatchedIncidentAuthority(
		ctx, rotator, incident, session, now,
	)
	return rotated || err != nil, err
}
