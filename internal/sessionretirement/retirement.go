// Package sessionretirement closes and cleans up a durable lane's outgoing
// Coop workspace without preserving revoked authority.
package sessionretirement

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/sessionauthority"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
)

type Client interface {
	sessionauthority.Client
	Close(context.Context, string, string, int64) (coop.Session, coop.Operation, error)
}

type CleanupScheduler interface {
	ScheduleCleanup(context.Context, string, string, string, bool, time.Time) error
}

func Retire(
	ctx context.Context,
	client Client,
	cleanup CleanupScheduler,
	sessionID, closeKey, reason string,
	now time.Time,
	handoff func() bool,
) error {
	session, err := client.GetSession(ctx, sessionID)
	if err != nil {
		if !missingSession(err) {
			return err
		}
		return cleanup.ScheduleCleanup(ctx, sessionID, "", reason, false, now.UTC())
	}
	if sessioncreate.TerminalState(session.State) {
		return cleanup.ScheduleCleanup(ctx, sessionID, "", reason, false, now.UTC())
	}
	if !session.RepositoryReadOnly {
		if session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
			session, _, err = sessionauthority.Revoke(ctx, client, session)
			if err != nil {
				return err
			}
		}
		return closeAndClean(ctx, client, cleanup, sessionID, session.Revision, closeKey, reason, now)
	}
	if session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
		return fmt.Errorf(
			"read-only session %s still has active or queued work; defer rotation until it finishes",
			sessionID,
		)
	}
	if handoff != nil && handoff() {
		return nil
	}
	return closeAndClean(ctx, client, cleanup, sessionID, session.Revision, closeKey, reason, now)
}

func missingSession(err error) bool {
	var apiErr *coop.APIError
	return errors.As(err, &apiErr) &&
		(apiErr.Status == 404 || apiErr.Code == "not_found" || apiErr.Code == "session_not_found")
}

func closeAndClean(
	ctx context.Context,
	client Client,
	cleanup CleanupScheduler,
	sessionID string,
	revision int64,
	closeKey, reason string,
	now time.Time,
) error {
	if _, _, err := client.Close(ctx, closeKey, sessionID, revision); err != nil {
		return err
	}
	return cleanup.ScheduleCleanup(ctx, sessionID, "", reason, false, now.UTC())
}
