package store

import (
	"context"
	"testing"
	"time"
)

// A refusal during finalization returns the run to the finalization lane, not
// to pending.
//
// The turn already produced a result; only reading it was refused. Sending the
// run back to pending would discard an answer that exists and re-run the work
// that produced it.
func TestRequeuedFinalizationStaysInItsLane(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	seedRunInState(t, st, "run_refused", "applying")

	next := time.Now().UTC().Add(5 * time.Minute)
	if err := st.RequeueRateLimitedFinalization(
		ctx, "run_refused", "ACP request was rejected", next,
	); err != nil {
		t.Fatalf("requeue: %v", err)
	}
	run, err := st.GetAgentRun(ctx, "run_refused")
	if err != nil {
		t.Fatal(err)
	}
	if run.State != "applying" {
		t.Fatalf("state = %q, want applying so the finished turn is not re-run", run.State)
	}
	if run.Failures != 0 {
		t.Fatalf("a refusal spent an attempt: failures = %d", run.Failures)
	}
	if run.LastError == "" {
		t.Fatal("last_error is empty; nothing would show why the run is waiting")
	}
	if !run.NextAttemptAt.After(time.Now().UTC()) {
		t.Fatalf("not scheduled for a later attempt: %v", run.NextAttemptAt)
	}
}

// A run that is not finalizing must not be dragged into the finalization lane.
func TestRequeuedFinalizationRefusesTheWrongState(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	seedRunInState(t, st, "run_pending", "pending")

	err := st.RequeueRateLimitedFinalization(
		ctx, "run_pending", "ACP request was rejected", time.Now().UTC().Add(time.Minute),
	)
	if err == nil {
		t.Fatal("a pending run was moved into the finalization lane")
	}
}

func seedRunInState(t *testing.T, st *Store, id, state string) {
	t.Helper()
	if _, err := st.db.ExecContext(context.Background(), `
		INSERT INTO agent_runs (id, mode, channel_id, thread_ts, conversation_key,
		  source_kind, source_id, user_id, repository, prompt, idempotency_key,
		  state, created_at, updated_at, next_attempt_at)
		VALUES (?, 'triage','C1','1700.1','k','watch',?,'U1','repo','p',?,?,
		  '2026-08-07T12:00:00.000000000Z','2026-08-07T12:00:00.000000000Z',
		  '2026-08-07T12:00:00.000000000Z')`,
		id, id, "idem_"+id, state,
	); err != nil {
		t.Fatal(err)
	}
}
