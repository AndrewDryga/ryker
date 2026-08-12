package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestRetryAgentRunIfOwnedRequeuesCurrentOwner(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _ := queueKernelEpisode(t, st, "message-current")
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased run %s, want %s", leased.ID, run.ID)
	}

	applied, err := st.RetryAgentRunIfOwned(ctx, run.ID, "temporary failure", time.Now().UTC(), false)
	if err != nil {
		t.Fatal(err)
	}
	if !applied {
		t.Fatal("current worker did not apply its retry")
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunPending || stored.Failures != 1 {
		t.Fatalf("stored run = state %s failures %d, want pending / 1", stored.State, stored.Failures)
	}
}

func TestFinishAgentRunFailureCommitsLifecycleAndOutboxAtomically(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "terminal-request")
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	delivery := &core.SlackDelivery{
		ID: "watch_failure_terminal-request", EpisodeID: episode.ID,
		ChannelID: episode.Destination.ChannelID, ThreadTS: episode.Destination.ThreadTS,
		Operation: "post", Kind: "notice", Body: []byte(`{"text":"failed"}`),
		ResponseRoot: true,
	}
	state, applied, err := st.FinishAgentRunFailure(ctx, run.ID, "terminal failure", delivery, AgentRunFailureEffects{
		StatusChannelID: "COPS", StatusThreadTS: "1700.100",
	})
	if err != nil || !applied || state != core.AgentRunFailed {
		t.Fatalf("finish failure = %s, %t, %v", state, applied, err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed || stored.TerminalState != string(core.AgentRunFailed) {
		t.Fatalf("stored run = %+v, %v", stored, err)
	}
	attempt, err := st.GetEpisodeAttempt(ctx, run.AttemptID)
	if err != nil || attempt.State != core.AttemptFailed {
		t.Fatalf("attempt = %+v, %v", attempt, err)
	}
	current, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil || current.State != core.EpisodeFailed {
		t.Fatalf("episode = %+v, %v", current, err)
	}
	outbox, err := st.GetSlackDelivery(ctx, delivery.ID)
	if err != nil || outbox.State != "pending" || outbox.AgentRunID != run.ID || !outbox.ResponseRoot {
		t.Fatalf("outbox = %+v, %v", outbox, err)
	}
	if status, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_status_clear_failure_"); err != nil || len(status) != 1 {
		rows, _ := st.db.QueryContext(ctx, `SELECT id, operation, state FROM slack_deliveries`)
		defer rows.Close()
		for rows.Next() {
			var id, op, state string
			_ = rows.Scan(&id, &op, &state)
			t.Log(id, op, state)
		}
		t.Fatalf("status outbox = %+v, %v", status, err)
	}
}

func TestFinishAgentRunFailureCannotNotifyForOlderAttempt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first, episode := queueKernelEpisode(t, st, "older-request")
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET state = 'running' WHERE id = ?`, first.ID,
	); err != nil {
		t.Fatal(err)
	}
	second, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: first.ConversationKey,
		SourceKind: "watch", SourceID: "newer-request", Prompt: "newer",
	})
	if err != nil || !created {
		t.Fatalf("queue replacement = %+v, %t, %v", second, created, err)
	}
	delivery := &core.SlackDelivery{
		ID: "watch_failure_older-request", EpisodeID: episode.ID,
		ChannelID: episode.Destination.ChannelID, Operation: "post", Kind: "notice",
		Body: []byte(`{"text":"failed"}`), ResponseRoot: true,
	}
	_, applied, err := st.FinishAgentRunFailure(ctx, first.ID, "stale worker", delivery, AgentRunFailureEffects{})
	if err != nil || applied {
		t.Fatalf("stale finish = applied %t, %v", applied, err)
	}
	if _, err := st.GetSlackDelivery(ctx, delivery.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stale worker created delivery: %v", err)
	}
	current, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil || current.LatestAttemptID != second.AttemptID || current.State == core.EpisodeFailed {
		t.Fatalf("replacement episode = %+v, %v", current, err)
	}
}

func TestOlderFailureCannotRetireSharedBindingsOwnedByNewEpisode(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Intelligence.BindChannelSession(
		ctx, "COPS", "repo", "ses-shared", 4, 2, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.500",
		ConversationKey: "channel:COPS:older", SourceKind: "watch", SourceID: "older-binding",
		SessionID: "ses-shared", SessionGeneration: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	newer, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.500",
		ConversationKey: "channel:COPS:newer", SourceKind: "watch", SourceID: "newer-binding",
		SessionID: "ses-shared", SessionGeneration: 2,
		State: core.AgentRunRunning, StartedAt: time.Now().UTC(),
	})
	if err != nil || !created {
		t.Fatalf("queue newer episode = %+v, %t, %v", newer, created, err)
	}
	failure := &core.SlackDelivery{
		ID: "watch_failure_older-binding", AgentRunID: older.ID,
		ChannelID: "COPS", ThreadTS: "1700.500", Operation: "post", Kind: "notice",
		Body: []byte(`{"text":"old failed"}`), ResponseRoot: true,
	}
	_, applied, err := st.FinishAgentRunFailure(ctx, older.ID, "old failed", failure, AgentRunFailureEffects{
		StatusChannelID: "COPS", StatusThreadTS: "1700.500",
		SessionChannelID: "COPS", SessionID: "ses-shared", SessionGeneration: 2,
	})
	if err != nil || !applied {
		t.Fatalf("finish older failure = %t, %v", applied, err)
	}
	memory, err := st.Intelligence.GetChannelMemory(ctx, "COPS")
	if err != nil || memory.SessionID != "ses-shared" || memory.Generation != 2 {
		t.Fatalf("newer session binding = %+v, %v", memory, err)
	}
	if _, err := st.NextCleanup(ctx, time.Now().Add(time.Hour)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("older failure scheduled shared session cleanup: %v", err)
	}
	if clears, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_status_clear_failure_"); err != nil || len(clears) != 0 {
		t.Fatalf("older failure cleared newer status = %+v, %v", clears, err)
	}
	if _, err := st.GetSlackDelivery(ctx, failure.ID); err != nil {
		t.Fatalf("older failure notice was not retained: %v", err)
	}
}

func TestTriageSessionBindingRefusesSessionAlreadyDetachedByFailure(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Intelligence.BindChannelSession(
		ctx, "COPS", "repo", "ses-shared", 4, 2, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.600",
		ConversationKey: "channel:COPS:older-detach", SourceKind: "watch", SourceID: "older-detach",
		SessionID: "ses-shared", SessionGeneration: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	newer, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1700.700",
		ConversationKey: "channel:COPS:newer-resolved", SourceKind: "watch", SourceID: "newer-resolved",
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil || leased.ID != newer.ID {
		t.Fatalf("lease newer run = %+v, %v", leased, err)
	}
	if _, applied, err := st.FinishAgentRunFailure(ctx, older.ID, "old failure", nil, AgentRunFailureEffects{
		SessionChannelID: "COPS", SessionID: "ses-shared", SessionGeneration: 2,
	}); err != nil || !applied {
		t.Fatalf("detach failed session = %t, %v", applied, err)
	}
	memory, err := st.Intelligence.GetChannelMemory(ctx, "COPS")
	if err != nil || memory.SessionID != "" || memory.Generation != 3 {
		t.Fatalf("detached session generation = %+v, %v", memory, err)
	}
	if err := st.Intelligence.BindChannelSession(
		ctx, "COPS", "repo", "ses-shared", 4, 3, time.Now().UTC(),
	); err == nil {
		t.Fatal("cleanup-owned session was rebound to channel memory")
	}
	if err := st.BindTriageAgentRunSession(
		ctx, newer.ID, "COPS", "ses-shared", 3, false, "repo", 0, []byte(`{}`),
	); err == nil {
		t.Fatal("new run bound the detached session it resolved before the failure")
	}
	stored, err := st.GetAgentRun(ctx, newer.ID)
	if err != nil || stored.SessionID != "" {
		t.Fatalf("newer run bound orphaned session = %+v, %v", stored, err)
	}
}

func TestLeaseAgentRunFinalizationSkipsOlderEpisodeAttempt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first, episode := queueKernelEpisode(t, st, "older-result")
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET state = 'running' WHERE id = ?`, first.ID,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, first.ID, "completed", []byte(`{"action":"reply"}`), "", 1); err != nil {
		t.Fatal(err)
	}
	second, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: first.ConversationKey,
		SourceKind: "recheck", SourceID: "newer-result", Prompt: "newer",
	})
	if err != nil || !created {
		t.Fatalf("queue replacement = %+v, %t, %v", second, created, err)
	}
	if _, err := st.LeaseAgentRunFinalization(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("lease stale finalization = %v", err)
	}
	stored, err := st.GetAgentRun(ctx, first.ID)
	if err != nil || stored.State != core.AgentRunSuperseded {
		t.Fatalf("older finalization = %+v, %v", stored, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil || leased.ID != second.ID {
		t.Fatalf("newer attempt = %+v, %v", leased, err)
	}
}

func TestFinalizationClaimRejectsNewEpisodeAttempt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first, episode := queueKernelEpisode(t, st, "claimed-result")
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET state = 'running' WHERE id = ?`, first.ID,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, first.ID, "completed", []byte(`{"action":"reply"}`), "", 1); err != nil {
		t.Fatal(err)
	}
	claimed, err := st.LeaseAgentRunFinalization(ctx)
	if err != nil || claimed.ID != first.ID {
		t.Fatalf("claim finalization = %+v, %v", claimed, err)
	}
	if _, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: first.ConversationKey,
		SourceKind: "recheck", SourceID: "too-late", Prompt: "newer",
	}); !errors.Is(err, ErrConflict) || created {
		t.Fatalf("queue after finalization claim = %t, %v", created, err)
	}
}

func TestFinishAgentRunFailurePreservesAlreadyStagedSuccess(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: "thread:COPS:success",
		SourceKind: "watch", SourceID: "success-source", State: core.AgentRunRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, run.ID, "completed", []byte(`{"action":"reply"}`), "", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "opaque-success", EpisodeID: episode.ID, AgentRunID: run.ID,
		SourceInputID: run.SourceID, Operation: "post", Kind: "notice",
		ChannelID: episode.Destination.ChannelID, ThreadTS: episode.Destination.ThreadTS,
		Body: []byte(`{"text":"answer"}`), ResponseRoot: true,
	})
	if err != nil || !created {
		t.Fatalf("stage success = %t, %v", created, err)
	}
	failure := &core.SlackDelivery{
		ID: "watch_failure_success-source", EpisodeID: episode.ID,
		ChannelID: episode.Destination.ChannelID, Operation: "post", Kind: "notice",
		Body: []byte(`{"text":"failed"}`), ResponseRoot: true,
	}
	state, applied, err := st.FinishAgentRunFailure(ctx, run.ID, "late finalization error", failure, AgentRunFailureEffects{})
	if err != nil || !applied || state != core.AgentRunCompleted {
		t.Fatalf("preserve success = %s, %t, %v", state, applied, err)
	}
	if _, err := st.GetSlackDelivery(ctx, failure.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("contradictory failure delivery exists: %v", err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunCompleted {
		t.Fatalf("stored success = %+v, %v", stored, err)
	}
}

func TestRetriedRunDoesNotMistakeItsOldFailureNoticeForSuccess(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := queueKernelEpisode(t, st, "retry-after-failure")
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	firstNotice := &core.SlackDelivery{
		ID: "out_run_" + run.ID, EpisodeID: episode.ID,
		AgentRunID: run.ID, SourceInputID: run.SourceID,
		ChannelID: episode.Destination.ChannelID, Operation: "post", Kind: "notice",
		Body: []byte(`{"text":"first failure"}`), ResponseRoot: true,
	}
	if state, applied, err := st.FinishAgentRunFailure(
		ctx, run.ID, "first failure", firstNotice, AgentRunFailureEffects{},
	); err != nil || !applied || state != core.AgentRunFailed {
		t.Fatalf("first failure = %s, %t, %v", state, applied, err)
	}
	if err := st.RequeueFailedAgentRun(ctx, run.ID, "operator retried"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET state = 'running' WHERE id = ?`, run.ID,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, run.ID, "completed", []byte(`{"action":"reply"}`), "", 2,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
	secondNotice := &core.SlackDelivery{
		ID: "out_run_finalization_failure_" + run.ID, EpisodeID: episode.ID,
		AgentRunID: run.ID, SourceInputID: run.SourceID,
		ChannelID: episode.Destination.ChannelID, Operation: "post", Kind: "notice",
		Body: []byte(`{"text":"retry finalization failed"}`), ResponseRoot: true,
	}
	state, applied, err := st.FinishAgentRunFailure(
		ctx, run.ID, "retry finalization failed", secondNotice, AgentRunFailureEffects{},
	)
	if err != nil || !applied || state != core.AgentRunFailed {
		t.Fatalf("retried failure = %s, %t, %v", state, applied, err)
	}
	if _, err := st.GetSlackDelivery(ctx, secondNotice.ID); err != nil {
		t.Fatalf("retry failure notice missing: %v", err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("retried run = %+v, %v", stored, err)
	}
}

func TestRetriedTaskDoesNotMistakeItsOldCardForSuccess(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, created, err := st.CreateEngineeringTask(
		ctx, "repo", "retry-task", "Retry task", "summary",
		"UOP", "COPS", "1700.400", 100,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", incident, created, err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID, ChannelID: "COPS",
		ConversationKey: "incident:" + incident.ID, SourceKind: "incident", SourceID: incident.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET state = 'preparing' WHERE id = ?`, run.ID,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.TaskCards.SetUpdate(ctx, incident.ID, run.ID, "The first execution failed."); err != nil {
		t.Fatal(err)
	}
	if state, applied, err := st.FinishAgentRunFailure(
		ctx, run.ID, "first task failure", nil, AgentRunFailureEffects{},
	); err != nil || !applied || state != core.AgentRunFailed {
		t.Fatalf("first task failure = %s, %t, %v", state, applied, err)
	}
	beforeRetry, err := st.GetIncident(ctx, incident.ID)
	if err != nil || beforeRetry.LatestUpdateRunKey == "" {
		t.Fatalf("first card execution key = %+v, %v", beforeRetry, err)
	}
	if err := st.RequeueFailedAgentRun(ctx, run.ID, "operator retried"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET state = 'running' WHERE id = ?`, run.ID,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, run.ID, "completed", []byte(`{"action":"reply"}`), "", 2,
	); err != nil {
		t.Fatal(err)
	}
	retried, err := st.BeginAgentRunFinalization(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if retried.IdempotencyKey == beforeRetry.LatestUpdateRunKey {
		t.Fatal("retry reused the execution key recorded by the old card")
	}
	state, applied, err := st.FinishAgentRunFailure(
		ctx, run.ID, "retry finalization failed", nil, AgentRunFailureEffects{},
	)
	if err != nil || !applied || state != core.AgentRunFailed {
		t.Fatalf("retried task failure = %s, %t, %v", state, applied, err)
	}
}

func TestRetryAgentRunIfOwnedAcceptsVerifiedSupersession(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _ := queueKernelEpisode(t, st, "message-stale")
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased run %s, want %s", leased.ID, run.ID)
	}
	if err := st.SupersedeAgentRun(ctx, run.ID, "a newer correlated event took over"); err != nil {
		t.Fatal(err)
	}

	applied, err := st.RetryAgentRunIfOwned(ctx, run.ID, "stale worker failed", time.Now().UTC(), false)
	if err != nil {
		t.Fatal(err)
	}
	if applied {
		t.Fatal("stale worker claimed it changed a superseded run")
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunSuperseded || stored.Failures != 0 {
		t.Fatalf("stored run = state %s failures %d, want superseded / 0", stored.State, stored.Failures)
	}
}
