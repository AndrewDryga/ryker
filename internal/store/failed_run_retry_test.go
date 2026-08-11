package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func failKernelEpisode(t *testing.T, st *Store, source string) core.AgentRun {
	t.Helper()
	ctx := context.Background()
	run, _ := queueKernelEpisode(t, st, source)
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased %s, queued %s", leased.ID, run.ID)
	}
	if err := st.RetryAgentRun(ctx, run.ID, "provider exploded", time.Now().UTC(), true); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunFailed {
		t.Fatalf("run state = %s, want failed", stored.State)
	}
	return stored
}

// A failed run goes back to pending with a fresh idempotency key, and its
// terminal episode reopens. The key matters: Coop deduplicates submissions by
// it, so replaying the old key would return the already-failed turn instead of
// starting a new one — a retry that reports the same failure instantly.
func TestRequeueFailedAgentRunReopensTheEpisode(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := failKernelEpisode(t, st, "message-1")
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeFailed {
		t.Fatalf("episode state = %s, want failed", episode.State)
	}

	if err := st.RequeueFailedAgentRun(ctx, run.ID, "operator retried from the control plane"); err != nil {
		t.Fatal(err)
	}
	requeued, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if requeued.State != core.AgentRunPending || requeued.TerminalState != "" {
		t.Fatalf("run = %s / terminal %q, want pending with no terminal state",
			requeued.State, requeued.TerminalState)
	}
	if requeued.IdempotencyKey == run.IdempotencyKey {
		t.Fatal("idempotency key was not refreshed; Coop would replay the failed turn")
	}
	reopened, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.State != core.EpisodeAcknowledged || !reopened.CompletedAt.IsZero() {
		t.Fatalf("episode = %s completed=%v, want acknowledged and incomplete",
			reopened.State, reopened.CompletedAt)
	}
	// The ordinary worker picks it up again — the whole point of the retry.
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased %s, want the requeued run %s", leased.ID, run.ID)
	}

	// The same persisted run may be explicitly retried more than once. Each
	// retry is a new execution generation even though it retains the original
	// attempt identity for its context and audit history.
	if err := st.RetryAgentRun(ctx, run.ID, "provider exploded again", time.Now().UTC(), true); err != nil {
		t.Fatal(err)
	}
	if err := st.RequeueFailedAgentRun(ctx, run.ID, "operator retried again"); err != nil {
		t.Fatal(err)
	}
	leased, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased %s on the second retry, want %s", leased.ID, run.ID)
	}
	afterSecondRetry, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if afterSecondRetry.State != core.EpisodePlanning {
		t.Fatalf("episode state after the second retry = %s, want planning", afterSecondRetry.State)
	}
}

// Only the latest attempt may be retried, and the refusal says why. Reviving an
// older attempt would race the newer one for the same episode, and a retry
// button that silently does nothing is the defect the dashboard exists to stop.
func TestRequeueFailedAgentRunRefusesSupersededAttempts(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := failKernelEpisode(t, st, "message-1")
	if err := st.RequeueFailedAgentRun(ctx, run.ID, "first retry"); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	second, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS",
		ConversationKey: episode.ID, SourceKind: "watch", SourceID: "message-1-again",
		Prompt: "Investigate again",
	})
	if err != nil || !created {
		t.Fatalf("queue second attempt: created=%t err=%v", created, err)
	}
	// The first run fails again, now that a second attempt is on record.
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased %s, want the first run %s", leased.ID, run.ID)
	}
	if err := st.RetryAgentRun(ctx, run.ID, "provider exploded again", time.Now().UTC(), true); err != nil {
		t.Fatal(err)
	}

	err = st.RequeueFailedAgentRun(ctx, run.ID, "operator retried a stale run")
	if err == nil {
		t.Fatal("a superseded attempt was requeued; it would race the newer one")
	}
	if !strings.Contains(err.Error(), "newer attempt") {
		t.Errorf("refusal does not say why: %v", err)
	}
	// A run that is not failed is refused by state, with the state named.
	err = st.RequeueFailedAgentRun(ctx, second.ID, "operator retried a pending run")
	if err == nil || !strings.Contains(err.Error(), "not failed") {
		t.Errorf("a pending run was accepted for retry: %v", err)
	}
}
