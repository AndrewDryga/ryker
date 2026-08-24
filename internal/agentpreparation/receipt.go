// Package agentpreparation coordinates durable pre-submission receipts.
package agentpreparation

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/retrydelay"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/turncapacity"
)

const receiptTimeout = 5 * time.Second

func Recover(
	ctx context.Context,
	ledger *store.Store,
	now time.Time,
	stallAfter time.Duration,
	log *slog.Logger,
) error {
	recovered, err := store.RecoverStaleAgentRunPreparations(
		ctx, ledger, now.UTC().Add(-stallAfter),
	)
	if err == nil && recovered > 0 && log != nil {
		log.Warn("requeued abandoned agent-run preparation leases", "count", recovered)
	}
	return err
}

func Defer(
	ctx context.Context,
	ledger *store.Store,
	runID string,
	contextJSON []byte,
	detail string,
	next time.Time,
	preparingWorkspace bool,
) error {
	receiptCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), receiptTimeout)
	defer cancel()
	return store.DeferTriageAgentRun(
		receiptCtx, ledger, runID, contextJSON, detail, next, preparingWorkspace,
	)
}

func AdvanceContext(
	state *decisionpkg.WatchTurnState,
	observedGeneration int,
	cause error,
) ([]byte, bool, bool, error) {
	var limitErr *turncapacity.LimitError
	limitReached := errors.As(cause, &limitErr)
	unusable := sessioncreate.TerminalFailure(cause) || limitReached
	next := retrydelay.NextSessionGeneration(state.Generation, observedGeneration, unusable)
	advanced := next > state.Generation
	if advanced {
		state.Generation = next
	}
	contextJSON, err := json.Marshal(*state)
	return contextJSON, advanced, limitReached, err
}

func RetryDelay(cause error) time.Duration {
	var pending *coop.OperationPendingError
	if errors.As(cause, &pending) {
		return time.Second
	}
	return 30 * time.Second
}

func Persist(
	ctx context.Context,
	ledger *store.Store,
	runID string,
	contextJSON []byte,
) error {
	receiptCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), receiptTimeout)
	defer cancel()
	return ledger.SetAgentRunContext(receiptCtx, runID, contextJSON)
}

func Notify(
	ctx context.Context,
	log *slog.Logger,
	runID string,
	notify func(context.Context) error,
) {
	noticeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), receiptTimeout)
	defer cancel()
	if err := notify(noticeCtx); err != nil && log != nil {
		log.Warn("could not publish repository preparation status", "run", runID, "error", err)
	}
}

func DeferAndNotify(
	ctx context.Context,
	ledger *store.Store,
	log *slog.Logger,
	runID string,
	contextJSON []byte,
	detail string,
	next time.Time,
	preparingWorkspace bool,
	notify func(context.Context) error,
) error {
	if err := Defer(ctx, ledger, runID, contextJSON, detail, next, preparingWorkspace); err != nil {
		return err
	}
	Notify(ctx, log, runID, notify)
	return nil
}
