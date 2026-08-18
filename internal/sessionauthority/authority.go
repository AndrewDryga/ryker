// Package sessionauthority revokes Coop workspace authority that a durable
// Responder lane no longer grants.
package sessionauthority

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
)

type Client interface {
	ListTurns(context.Context, string, int64, int) ([]coop.Turn, error)
	Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error)
	GetSession(context.Context, string) (coop.Session, error)
	GetTurn(context.Context, string, string) (coop.Turn, error)
}

type CandidateClient interface {
	Client
	Close(context.Context, string, string, int64) (coop.Session, coop.Operation, error)
}

type CleanupScheduler interface {
	ScheduleCleanup(context.Context, string, string, string, bool, time.Time) error
}

func RejectCandidate(
	ctx context.Context,
	client CandidateClient,
	cleanup CleanupScheduler,
	session coop.Session,
	ownerID string,
	lane string,
	now time.Time,
) error {
	reason := lane + " session lacks reusable repository authority"
	// Ownership first: a transport failure during revocation or close must not
	// make this managed session disappear from durable cleanup.
	if err := cleanup.ScheduleCleanup(
		ctx, session.ID, ownerID,
		reason,
		false, now.UTC(),
	); err != nil {
		return err
	}
	if sessioncreate.TerminalState(session.State) {
		return nil
	}
	if session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
		var err error
		session, _, err = Revoke(ctx, client, session)
		if err != nil {
			return err
		}
	}
	for range 2 {
		key := "responder:reject-session:" + session.ID + ":" +
			strconv.FormatInt(session.Revision, 10)
		if _, _, err := client.Close(ctx, key, session.ID, session.Revision); err == nil {
			return nil
		} else if !sessioncreate.RevisionConflict(err) {
			return fmt.Errorf("%s: %w", reason, err)
		}
		latest, err := client.GetSession(ctx, session.ID)
		if err != nil {
			return err
		}
		if sessioncreate.TerminalState(latest.State) {
			return nil
		}
		session = latest
	}
	return errors.New(reason + ": Coop revision kept changing while closing it")
}

var ErrConvergence = errors.New("repository authority convergence is incomplete")

func Revoke(
	ctx context.Context,
	client Client,
	session coop.Session,
) (coop.Session, bool, error) {
	turns, err := client.ListTurns(ctx, session.ID, 0, 1000)
	if err != nil {
		return session, false, err
	}
	revoked := false
	for _, turn := range turns {
		if !nonterminal(turn.State) {
			continue
		}
		for attempt := 0; attempt < 2; attempt++ {
			_, _, cancelErr := client.Cancel(
				ctx, "responder:revoke-writable:"+session.ID+":"+turn.ID+":"+
					strconv.FormatInt(session.Revision, 10),
				session.ID, turn.ID, session.Revision,
			)
			if cancelErr == nil {
				revoked = true
				session, err = client.GetSession(ctx, session.ID)
				if err != nil {
					return coop.Session{}, revoked, err
				}
				break
			}
			if !sessioncreate.RevisionConflict(cancelErr) {
				latest, getErr := client.GetTurn(ctx, session.ID, turn.ID)
				if getErr == nil && !nonterminal(latest.State) {
					break
				}
				return session, revoked, cancelErr
			}
			session, err = client.GetSession(ctx, session.ID)
			if err != nil {
				return coop.Session{}, revoked, errors.Join(cancelErr, err)
			}
		}
	}
	if session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
		return session, revoked, errors.New(
			"legacy writable session reports active or queued work that Coop did not enumerate",
		)
	}
	return session, revoked, nil
}

func nonterminal(state string) bool {
	return state == "queued" || state == "starting" || state == "running"
}
