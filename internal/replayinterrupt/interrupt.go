// Package replayinterrupt converges cancellation of the exact Coop turn owned
// by one replay execution generation.
package replayinterrupt

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

type Coop interface {
	GetSession(context.Context, string) (coop.Session, error)
	GetTurn(context.Context, string, string) (coop.Turn, error)
	OperationByKey(context.Context, string) (coop.Operation, error)
	Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error)
}

var ErrSubmitOperationNotFound = errors.New("Coop submit operation not found")

// Converge retries one durable remote-interruption obligation and records its
// next state through the supplied persistence callbacks.
func Converge(
	ctx context.Context,
	client Coop,
	run core.AgentRun,
	settleMissing bool,
	complete func(context.Context, string) error,
	retry func(context.Context, string, string, time.Time) error,
) error {
	err := Cancel(ctx, client, run)
	if settleMissing && errors.Is(err, ErrSubmitOperationNotFound) {
		err = nil
	}
	if err != nil {
		if retry != nil {
			_ = retry(context.WithoutCancel(ctx), run.IdempotencyKey, err.Error(), time.Now().UTC().Add(time.Minute))
		}
		return err
	}
	if complete != nil {
		return complete(context.WithoutCancel(ctx), run.IdempotencyKey)
	}
	return nil
}

func Cancel(ctx context.Context, client Coop, run core.AgentRun) error {
	turnID := run.CoopTurnID
	if turnID == "" {
		op, err := client.OperationByKey(ctx, run.IdempotencyKey)
		if err != nil {
			var apiErr *coop.APIError
			if errors.As(err, &apiErr) && (apiErr.Status == 404 || apiErr.Code == "not_found" || apiErr.Code == "operation_not_found") {
				return fmt.Errorf("%w: %v", ErrSubmitOperationNotFound, err)
			}
			return fmt.Errorf("recover submitted Coop turn: %w", err)
		}
		if op.Method == "SubmitTurn" && op.State == "failed" {
			return nil
		}
		if op.State != "succeeded" || op.ResourceType != "turn" || op.ResourceID == "" {
			return fmt.Errorf("recover submitted Coop turn: operation is %s", op.State)
		}
		turnID = op.ResourceID
	}
	if turn, err := client.GetTurn(ctx, run.SessionID, turnID); err == nil && terminal(turn.State) {
		return nil
	}
	var last error
	for range 3 {
		session, err := client.GetSession(ctx, run.SessionID)
		if err != nil {
			return err
		}
		_, _, err = client.Cancel(
			ctx, fmt.Sprintf("responder:replay-timeout:%s:r%d", run.IdempotencyKey, session.Revision),
			run.SessionID, turnID, session.Revision,
		)
		if err == nil {
			return nil
		}
		if turn, getErr := client.GetTurn(ctx, run.SessionID, turnID); getErr == nil && terminal(turn.State) {
			return nil
		}
		last = err
		var apiErr *coop.APIError
		if !errors.As(err, &apiErr) || apiErr.Code != "revision_conflict" {
			return err
		}
	}
	return last
}

func terminal(state string) bool {
	switch state {
	case "completed", "failed", "cancelled", "interrupted", "budget_exhausted":
		return true
	default:
		return false
	}
}
