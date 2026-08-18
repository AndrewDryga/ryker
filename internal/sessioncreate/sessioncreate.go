// Package sessioncreate owns idempotent session-create retry semantics.
package sessioncreate

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

type GenerationAdvancer interface {
	AdvanceSessionGeneration(context.Context, string, int) error
}

func Key(base string, generation int) string {
	if generation <= 1 {
		return base
	}
	return base + ":" + strconv.Itoa(generation)
}

func TerminalFailure(err error) bool {
	var apiErr *coop.APIError
	return errors.As(err, &apiErr) && apiErr.Status >= 500 &&
		(apiErr.Code == "internal_error" || apiErr.Code == "repository_unavailable")
}

func IncidentFailure(
	ctx context.Context,
	advancer GenerationAdvancer,
	incidentID string,
	generation int,
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
	return core.WorkflowHolding, Status(cause), nil
}

func Status(err error) string {
	var pending *coop.OperationPendingError
	if errors.As(err, &pending) {
		return "Investigation queued; Coop is still preparing the workspace. " +
			"No model turn has started."
	}
	var apiErr *coop.APIError
	if errors.As(err, &apiErr) && apiErr.Code == "repository_unavailable" {
		detail := strings.TrimSpace(apiErr.Detail)
		if detail == "" {
			detail = "workspace preparation could not refresh the configured repository"
		}
		return "Investigation queued, but " + strings.TrimRight(detail, ".") + ". " +
			"No model turn has started; Responder will retry."
	}
	return "Investigation queued, but Coop could not finish workspace preparation. " +
		"No model turn has started; Responder will retry."
}
