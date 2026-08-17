package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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

// A refusal that arrives as a failed turn must requeue from 'running'.
//
// This is the path a refusal actually takes: Coop reports turn.failed while the
// run is still running, and the result is staged as terminal without any retry
// function seeing it. Three earlier guards all passed their tests and changed
// nothing, because none of them was on this path — the signature was a run in
// 'failed' with failure_count 0, which no retry function can produce.
func TestRunningRunIsRequeuedWhenTheProviderRefuses(t *testing.T) {
	ctx := context.Background()
	st := openAt(t, t.TempDir())
	// A real running run owns an episode and an attempt; requeueing updates
	// both, so a bare row would pass or fail for the wrong reason.
	seedEpisodeWithRun(t, st, "ep_run", "working",
		map[string][2]string{"run_running": {"running", "2026-08-07T12:00:00.000000000Z"}})
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO episode_attempts (id, episode_id, agent_run_id, attempt_number,
		  state, created_at, updated_at)
		VALUES ('att_run','ep_run','run_running',1,'running',
		  '2026-08-07T12:00:00.000000000Z','2026-08-07T12:00:00.000000000Z')`,
	); err != nil {
		t.Fatal(err)
	}
	// The episode has to name its latest attempt; the phase update joins
	// through it.
	if _, err := st.db.ExecContext(ctx,
		`UPDATE work_episodes SET latest_attempt_id = 'att_run' WHERE id = 'ep_run'`,
	); err != nil {
		t.Fatal(err)
	}

	next := time.Now().UTC().Add(5 * time.Minute)
	if err := st.RequeueRateLimitedAgentRun(
		ctx, "run_running", "ACP request was rejected", next, false,
	); err != nil {
		t.Fatalf("a running run could not be requeued, so the refusal becomes a failure: %v", err)
	}
	run, err := st.GetAgentRun(ctx, "run_running")
	if err != nil {
		t.Fatal(err)
	}
	if run.State != core.AgentRunPending {
		t.Fatalf("state = %q, want pending", run.State)
	}
	if run.Failures != 0 {
		t.Fatalf("a refusal spent an attempt: failures = %d", run.Failures)
	}
}
