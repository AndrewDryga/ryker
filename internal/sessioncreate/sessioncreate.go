// Package sessioncreate owns idempotent session-create retry semantics.
package sessioncreate

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

type GenerationAdvancer interface {
	AdvanceSessionGeneration(context.Context, string, int) error
}

type IncidentSessionRotator interface {
	RotateReadOnly(context.Context, string, string, int, string, time.Time) (bool, error)
}

// MaxReadOnlyCandidates bounds migration past legacy idempotency keys. A
// policy that keeps returning writable sessions is an authority error, not an
// invitation to create forks forever.
const MaxReadOnlyCandidates = 4

// MaxHistoricalCreateKeys bounds migration past durable keys created by older
// request shapes or failed repository preparation. These do not count as
// authority candidates because Coop did not return a workspace to judge.
const MaxHistoricalCreateKeys = 64

var ErrReadOnlyAuthority = errors.New("session lacks read-only repository authority")
var ErrWritableAuthority = errors.New("session lacks writable repository authority")
var ErrHistoricalCreateKeys = errors.New("historical session-create key window exhausted")

type OperationLookup interface {
	OperationByKey(context.Context, string) (coop.Operation, error)
}

// CandidateRequest is one bounded search for a session with the exact
// repository authority a lane grants. The caller owns how sessions are
// created, rejected, and durably advanced; this owns the shared convergence
// rules so watch, conversation, branch, and incident lanes cannot drift.
type CandidateRequest struct {
	Lane               string
	Generation         int
	RepositoryReadOnly bool
	BaseKey            string
	AttemptStarted     time.Time
	Lookup             OperationLookup
	Create             func(context.Context, string, int) (coop.Session, error)
	Reject             func(context.Context, coop.Session) error
	Advance            func(context.Context, int) error
}

func ResolveCandidates(
	ctx context.Context,
	request CandidateRequest,
) (coop.Session, int, error) {
	generation := max(request.Generation, 1)
	rejected, historical := 0, 0
	for {
		if err := ctx.Err(); err != nil {
			return coop.Session{}, generation, err
		}
		key := Key(request.BaseKey, generation)
		session, err := request.Create(ctx, key, generation)
		if err != nil {
			if !IdempotencyConflict(err) &&
				!HistoricalFailedCreate(ctx, request.Lookup, key, request.AttemptStarted, err) {
				return coop.Session{}, generation, err
			}
			historical++
			if historical >= MaxHistoricalCreateKeys {
				return coop.Session{}, generation, HistoricalCreateKeysError(request.Lane)
			}
			if request.Advance != nil {
				if err := request.Advance(ctx, generation); err != nil {
					return coop.Session{}, generation, err
				}
			}
			generation++
			continue
		}
		reusable := ReusableWritable(session)
		if request.RepositoryReadOnly {
			reusable = ReusableReadOnly(session)
		}
		if reusable {
			return session, generation, nil
		}
		if request.Reject == nil {
			return coop.Session{}, generation, errors.New("session candidate rejection is not configured")
		}
		if err := request.Reject(ctx, session); err != nil {
			return coop.Session{}, generation, err
		}
		if request.Advance != nil {
			if err := request.Advance(ctx, generation); err != nil {
				return coop.Session{}, generation, err
			}
		}
		generation++
		rejected++
		if rejected >= MaxReadOnlyCandidates {
			if request.RepositoryReadOnly {
				return coop.Session{}, generation, ReadOnlyAuthorityError(request.Lane)
			}
			return coop.Session{}, generation, WritableAuthorityError(request.Lane)
		}
	}
}

func HistoricalCreateKeysError(lane string) error {
	return fmt.Errorf(
		"%w: %s workspace preparation found %d consecutive historical request keys; no model turn started",
		ErrHistoricalCreateKeys, lane, MaxHistoricalCreateKeys,
	)
}

// HistoricalFailedCreate reports whether this exact key names a durable
// failed create that predates the current preparation attempt. A fresh failure
// returns to the scheduler; otherwise a persistent Coop outage could make one
// worker manufacture generations until the collision bound.
func HistoricalFailedCreate(
	ctx context.Context,
	lookup OperationLookup,
	key string,
	attemptStarted time.Time,
	cause error,
) bool {
	if !TerminalFailure(cause) || lookup == nil || attemptStarted.IsZero() {
		return false
	}
	operation, err := lookup.OperationByKey(ctx, key)
	if err != nil || operation.State != "failed" || operation.UpdatedAt.IsZero() ||
		!operation.UpdatedAt.Before(attemptStarted) {
		return false
	}
	return operation.Method == "CreateSession" || operation.Method == "CreateRemoteSession"
}

func ReadOnlyAuthorityError(lane string) error {
	return fmt.Errorf(
		"%w: Coop repeatedly created %s sessions without read-only repository authority; no model turn started",
		ErrReadOnlyAuthority,
		lane,
	)
}

func WritableAuthorityError(lane string) error {
	return fmt.Errorf(
		"%w: Coop repeatedly created %s sessions without writable repository authority; no model turn started",
		ErrWritableAuthority,
		lane,
	)
}

func Key(base string, generation int) string {
	if generation <= 1 {
		return base
	}
	return base + ":" + strconv.Itoa(generation)
}

func TerminalFailure(err error) bool {
	if errors.Is(err, ErrReadOnlyAuthority) || errors.Is(err, ErrHistoricalCreateKeys) {
		return true
	}
	var apiErr *coop.APIError
	return errors.As(err, &apiErr) && apiErr.Status >= 500 &&
		(apiErr.Code == "internal_error" || apiErr.Code == "repository_unavailable")
}

func RevisionConflict(err error) bool {
	var apiErr *coop.APIError
	return errors.As(err, &apiErr) && apiErr.Code == "revision_conflict"
}

func IdempotencyConflict(err error) bool {
	var apiErr *coop.APIError
	return errors.As(err, &apiErr) && apiErr.Code == "idempotency_conflict"
}

func SessionNotFound(err error) bool {
	var apiErr *coop.APIError
	return errors.As(err, &apiErr) &&
		(apiErr.Status == 404 || apiErr.Code == "not_found" ||
			apiErr.Code == "session_not_found")
}

func TerminalState(state string) bool {
	return state == "closed" || state == "discarded"
}

// ReusableReadOnly rejects both terminal sessions and legacy writable sessions.
func ReusableReadOnly(session coop.Session) bool {
	return !TerminalState(session.State) && session.RepositoryReadOnly
}

func ReusableWritable(session coop.Session) bool {
	return !TerminalState(session.State) && !session.RepositoryReadOnly
}

// ExactAuthority reports whether the bound workspace matches the lane. An
// ordinary incident is read-only; confirmed engineering work is writable.
func ExactAuthority(incident core.Incident, session coop.Session) bool {
	return incident.IsEngineeringTask() != session.RepositoryReadOnly
}

// RotateMismatchedIncidentAuthority releases authority that the lane's current
// policy does not grant, including legacy read-only engineering workspaces.
func RotateMismatchedIncidentAuthority(
	ctx context.Context,
	rotator IncidentSessionRotator,
	incident core.Incident,
	session coop.Session,
	now time.Time,
) (bool, error) {
	if ExactAuthority(incident, session) {
		return false, nil
	}
	if session.ActiveTurnID != "" || session.QueuedTurnCount != 0 {
		return false, errors.New("legacy writable incident session still has active or queued work")
	}
	reason := "ordinary incident session predates repository read-only enforcement"
	if incident.IsEngineeringTask() {
		reason = "engineering session predates writable repository authority enforcement"
	}
	return rotator.RotateReadOnly(
		ctx, incident.ID, session.ID, incident.CoopSessionGeneration,
		reason, now,
	)
}

func IncidentFailure(
	ctx context.Context,
	advancer GenerationAdvancer,
	incidentID string,
	generation int,
	repository string,
	cause error,
) (core.WorkflowState, string, error) {
	if TerminalFailure(cause) {
		if err := advancer.AdvanceSessionGeneration(ctx, incidentID, generation); err != nil &&
			!errors.Is(err, core.ErrConflict) {
			return "", "", errors.Join(cause, err)
		}
	}
	if !coop.Retryable(cause) {
		return core.WorkflowBlocked, strings.TrimSpace(cause.Error()), nil
	}
	return core.WorkflowHolding, Status(repository, cause), nil
}

func Status(repository string, err error) string {
	repository = strings.TrimSpace(repository)
	if repository == "" {
		repository = "the configured repository"
	}
	var pending *coop.OperationPendingError
	if errors.As(err, &pending) {
		return "Investigation queued; Coop is still preparing the workspace. " +
			"No model turn has started."
	}
	var apiErr *coop.APIError
	if errors.As(err, &apiErr) && apiErr.Code == "repository_unavailable" {
		return "Investigation queued, but workspace preparation could not refresh " + repository + ". " +
			"No model turn has started; Responder will retry."
	}
	return "Investigation queued, but Coop could not finish workspace preparation. " +
		"No model turn has started; Responder will retry."
}
