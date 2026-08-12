// Package replaycontrol owns cancellation of durable verification replays.
package replaycontrol

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/replayinterrupt"
)

type ActiveRuns interface{ Cancel(string, string) }

type Controller struct {
	CancelReplay func(context.Context, string, string, string) (core.AgentRun, bool, bool, error)
	Audit        func(context.Context, core.AuditEvent) error
	Coop         replayinterrupt.Coop
	Active       ActiveRuns
	Complete     func(context.Context, string) error
	Retry        func(context.Context, string, string, time.Time) error
	Log          *slog.Logger
}

// Interrupt retries one durable obligation without changing local run state.
// It is used by the scheduler after a prior HTTP/Coop failure or restart.
func (c Controller) Interrupt(ctx context.Context, run core.AgentRun, settleMissing bool) error {
	return replayinterrupt.Converge(ctx, c.Coop, run, settleMissing, c.Complete, c.Retry)
}

func (c Controller) Cancel(ctx context.Context, replayID, expectedRunKey, actor string) error {
	detail := "replay wait deadline expired; server work cancelled"
	run, applied, deliveryUncertain, err := c.CancelReplay(ctx, replayID, expectedRunKey, detail)
	if err != nil {
		return err
	}
	if run.ID != "" && c.Active != nil {
		c.Active.Cancel(run.ID, run.IdempotencyKey)
	}
	remoteOutcome := "not_running"
	var partial error
	if (applied || run.State == core.AgentRunCancelled) && run.SessionID != "" {
		cancelCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		cancelErr := replayinterrupt.Cancel(cancelCtx, c.Coop, run)
		cancel()
		if cancelErr != nil {
			remoteOutcome = "local_cancelled_remote_best_effort_failed"
			partial = fmt.Errorf("durable replay was cancelled, but Coop turn interruption was not confirmed: %w", cancelErr)
			if c.Log != nil {
				c.Log.Warn("cancel timed-out replay Coop turn", "run", run.ID, "error", cancelErr)
			}
			if c.Retry != nil {
				partial = errors.Join(partial, c.Retry(context.WithoutCancel(ctx), run.IdempotencyKey, cancelErr.Error(), time.Now().UTC().Add(time.Minute)))
			}
		} else {
			remoteOutcome = "local_and_remote_cancelled"
			if c.Complete != nil {
				partial = errors.Join(partial, c.Complete(context.WithoutCancel(ctx), run.IdempotencyKey))
			}
		}
	}
	if deliveryUncertain {
		remoteOutcome = "local_cancelled_slack_delivery_uncertain"
		partial = errors.Join(partial, errors.New(
			"durable replay was cancelled, but an in-flight Slack delivery requires reconciliation",
		))
	}
	receiptCtx, cancelReceipt := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancelReceipt()
	auditErr := c.Audit(receiptCtx, core.AuditEvent{
		Kind: "replay.cancel", ActorID: actor, ObjectID: replayID,
		Outcome: remoteOutcome, Detail: detail,
	})
	return errors.Join(partial, auditErr)
}
