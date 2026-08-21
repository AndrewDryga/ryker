// Package taskpublication serializes the durable handoff from a completed
// engineering feedback turn to its existing pull request.
package taskpublication

import (
	"context"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

type Policy struct {
	Now         func() time.Time
	RetryAt     func(int) time.Time
	Terminal    func(core.SlackInput, error, int) bool
	SafeError   func(error) string
	ControlKind string
	Publish     func(context.Context, core.SlackInput, core.Incident) error
}

type Result struct {
	TerminalFailure bool
	Detail          string
}

func Process(
	ctx context.Context,
	st *store.Store,
	input core.SlackInput,
	policy Policy,
) (Result, error) {
	incident, err := st.GetIncident(ctx, input.ActionValue)
	if errors.Is(err, store.ErrNotFound) {
		return Result{}, st.FinishSlackInput(ctx, input.ID)
	}
	if err != nil {
		return retry(ctx, st, input, policy, err)
	}
	if incident.LatestUpdateRunID != input.EventID {
		return Result{}, st.FinishSlackInput(ctx, input.ID)
	}
	if incident.ActiveTurnID != "" {
		return Result{}, st.RetrySlackInput(ctx, input.ID,
			"waiting for the current engineering turn", policy.Now().Add(2*time.Second), false)
	}
	control := input
	control.Kind = policy.ControlKind
	if err := policy.Publish(ctx, control, incident); err != nil {
		return retry(ctx, st, input, policy, err)
	}
	return Result{}, st.FinishSlackInput(ctx, input.ID)
}

func retry(
	ctx context.Context,
	st *store.Store,
	input core.SlackInput,
	policy Policy,
	cause error,
) (Result, error) {
	attempt := input.Failures + 1
	terminal := policy.Terminal(input, cause, attempt)
	detail := policy.SafeError(cause)
	err := st.RetrySlackInputFailure(ctx, input.ID, detail, policy.RetryAt(attempt), terminal)
	return Result{TerminalFailure: terminal, Detail: detail}, err
}
