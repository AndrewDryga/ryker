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

func TestReplacingAnAgentSessionDropsOnlyTheOldFrozenRevision(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _ := queueKernelEpisode(t, st, "replacement-session-revision")
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(
		ctx, run.ID, "session-old", 1, "repo", 0, []byte(`{}`),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.FreezeAgentRunRevision(ctx, run.ID, 32); err != nil {
		t.Fatal(err)
	}
	// Rebinding the same session is an idempotent retry and must retain the
	// frozen request revision.
	if err := st.BindAgentRunSession(
		ctx, run.ID, "session-old", 1, "repo", 0, []byte(`{}`),
	); err != nil {
		t.Fatal(err)
	}
	stable, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stable.ExpectedRevision != 32 {
		t.Fatalf("same-session revision = %+v, %v", stable, err)
	}
	if err := st.BindAgentRunSession(
		ctx, run.ID, "session-new", 2, "repo", 0, []byte(`{}`),
	); err != nil {
		t.Fatal(err)
	}
	replaced, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || replaced.ExpectedRevision != 0 {
		t.Fatalf("replacement-session revision = %+v, %v", replaced, err)
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

func TestTerminalProcessingFailureMarksSourceAndRetryQueuesRemoval(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "input_failure_marker", EnvelopeID: "env_failure_marker",
		Kind: "mention", TeamID: "T1", ChannelID: "COPS", MessageTS: "1700.200",
		UserID: "U1", Text: "investigate", ReceivedAt: time.Now().UTC(),
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	run, _ := queueKernelEpisode(t, st, input.ID)
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	state, applied, err := st.FinishAgentRunFailure(
		ctx, run.ID, "Coop returned HTTP 500", nil, AgentRunFailureEffects{},
	)
	if err != nil || !applied || state != core.AgentRunFailed {
		t.Fatalf("finish failure = %s, %t, %v", state, applied, err)
	}
	adds, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_failure_marker_add_")
	if err != nil || len(adds) != 1 {
		t.Fatalf("failure marker adds = %+v, %v", adds, err)
	}
	add := adds[0]
	if add.Operation != "reaction" || add.Kind != "failure_marker_add" ||
		add.ChannelID != input.ChannelID || add.MessageTS != input.MessageTS ||
		add.Status != "warning" || add.SourceInputID != input.ID ||
		add.AgentRunID != run.ID || add.AgentRunKey != run.IdempotencyKey {
		t.Fatalf("failure marker = %+v", add)
	}

	if err := st.RequeueFailedAgentRun(ctx, run.ID, "operator retried"); err != nil {
		t.Fatal(err)
	}
	add, err = st.GetSlackDelivery(ctx, add.ID)
	if err != nil || add.State != "superseded" {
		t.Fatalf("obsolete add = %+v, %v", add, err)
	}
	removes, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_failure_marker_remove_")
	if err != nil || len(removes) != 1 {
		t.Fatalf("failure marker removals = %+v, %v", removes, err)
	}
	remove := removes[0]
	if remove.Operation != "reaction" || remove.Kind != "failure_marker_remove" ||
		remove.Status != "warning" || remove.SourceInputID != "" ||
		remove.AgentRunKey == run.IdempotencyKey {
		t.Fatalf("failure marker removal = %+v", remove)
	}
}

func TestTerminalPreparationFailureMarksItsSlackSource(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "input_prepare_failure_marker", EnvelopeID: "env_prepare_failure_marker",
		Kind: "message", TeamID: "T1", ChannelID: "COPS", MessageTS: "1700.201",
		UserID: "U1", Text: "investigate", ReceivedAt: time.Now().UTC(),
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	run, _ := queueKernelEpisode(t, st, input.ID)
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if err := st.RetryAgentRun(ctx, run.ID, "internal operation failure", time.Now().UTC(), true); err != nil {
		t.Fatal(err)
	}
	markers, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_failure_marker_add_")
	if err != nil || len(markers) != 1 || markers[0].MessageTS != input.MessageTS {
		t.Fatalf("preparation failure markers = %+v, %v", markers, err)
	}
}

func TestStalePreparationFailureDoesNotMarkSourceOwnedByNewAttempt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "input_stale_failure_marker", EnvelopeID: "env_stale_failure_marker",
		Kind: "message", TeamID: "T1", ChannelID: "COPS", MessageTS: "1700.202",
		UserID: "U1", Text: "investigate", ReceivedAt: time.Now().UTC(),
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	older, episode := queueKernelEpisode(t, st, input.ID)
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `UPDATE agent_runs SET state = 'running' WHERE id = ?`, older.ID); err != nil {
		t.Fatal(err)
	}
	newer, created, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
		ConversationKey: older.ConversationKey, SourceKind: "recheck",
		SourceID: "newer_attempt", Prompt: "check again",
	})
	if err != nil || !created {
		t.Fatalf("queue successor = %+v, %t, %v", newer, created, err)
	}
	if _, err := st.db.ExecContext(ctx, `UPDATE agent_runs SET state = 'preparing' WHERE id = ?`, older.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.RetryAgentRun(ctx, older.ID, "stale HTTP 500", time.Now().UTC(), true); err != nil {
		t.Fatal(err)
	}
	if markers, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_failure_marker_add_"); err != nil || len(markers) != 0 {
		t.Fatalf("stale failure markers = %+v, %v", markers, err)
	}
	current, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil || current.LatestAttemptID != newer.AttemptID || current.State == core.EpisodeFailed {
		t.Fatalf("successor episode = %+v, %v", current, err)
	}
}

func TestPrivateReplayFailureDoesNotMarkPublicSlackMessage(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "input_private_failure", EnvelopeID: "replay-private:input_private_failure",
		Kind: "message", TeamID: "T1", ChannelID: "COPS", MessageTS: "1700.203",
		UserID: "U1", Text: "verify privately", ReceivedAt: time.Now().UTC(),
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	run, _ := queueKernelEpisode(t, st, input.ID)
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if err := st.RetryAgentRun(ctx, run.ID, "internal error", time.Now().UTC(), true); err != nil {
		t.Fatal(err)
	}
	if markers, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_failure_marker_add_"); err != nil || len(markers) != 0 {
		t.Fatalf("private replay markers = %+v, %v", markers, err)
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

// A provider-limited engineering run finally retried five hours late, after
// two newer turns had completed. It had never acquired a Coop turn, so its
// empty turn ID matched the parked card's empty active_turn_id and replaced the
// newer result with a raw 409 as operator work. A run without a turn may own a
// card failure only while it is still the newest run for that task.
func TestOlderRunWithoutTurnCannotOverwriteNewerTaskResult(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, created, err := st.CreateEngineeringTask(
		ctx, "repo", "EvStaleFailure", "Fix release startup",
		"Keep health available without discovery.", "UOPERATOR",
		"COPS", "1700.800", 100,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	older, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID,
		ChannelID: task.ChannelID, ThreadTS: task.ConversationThreadTS(),
		ConversationKey: "incident:" + task.ID, SourceKind: "slack", SourceID: "older",
		IdempotencyKey: "run:older",
	})
	if err != nil || !created {
		t.Fatalf("queue older run = %+v, %t, %v", older, created, err)
	}
	if _, err := st.db.ExecContext(ctx,
		`UPDATE agent_runs SET state = 'preparing' WHERE id = ?`, older.ID,
	); err != nil {
		t.Fatal(err)
	}
	newer, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunEngineeringTask, IncidentID: task.ID,
		ChannelID: task.ChannelID, ThreadTS: task.ConversationThreadTS(),
		ConversationKey: "incident:" + task.ID, SourceKind: "slack", SourceID: "newer",
		IdempotencyKey: "run:newer",
	})
	if err != nil || !created {
		t.Fatalf("queue newer run = %+v, %t, %v", newer, created, err)
	}
	if err := st.TaskCards.SetUpdate(ctx, task.ID, newer.ID, "The source fix is ready."); err != nil {
		t.Fatal(err)
	}
	if _, applied, err := st.FinishAgentRunFailure(
		ctx, older.ID, "Coop API revision_conflict (409)", nil, AgentRunFailureEffects{},
	); err != nil || !applied {
		t.Fatalf("finish older run = %t, %v", applied, err)
	}
	current, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if current.LastError != "" || current.LatestUpdate != "The source fix is ready." {
		t.Fatalf("newer task result was overwritten: %+v", current)
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

// A newer attempt takes over an episode from an attempt that has no answer to
// deliver, and only from that one.
//
// The replacement case is the one this guard was written for: an attempt failed,
// something queued another, and the failure must not be finalized underneath it.
//
// A completed result is the opposite case, and superseding it here was the
// fourth place a newer Grafana card destroyed finished work on 2026-08-16 —
// an alert stream is one episode now, so the next card queues its attempt while
// the previous investigation is still applying an answer that cost fifteen
// minutes and forty-seven tool calls. Delivering it strands nothing:
// setWorkEpisodePhaseTx already refuses to close a shared episode from an
// attempt that is no longer the latest.
func TestOnlyAnAnswerlessAttemptYieldsFinalizationToItsReplacement(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	stage := func(source, terminalState string) (core.AgentRun, core.AgentRun) {
		t.Helper()
		first, episode := queueKernelEpisode(t, st, source)
		if _, err := st.LeaseAgentRun(ctx); err != nil {
			t.Fatal(err)
		}
		if _, err := st.db.ExecContext(ctx,
			`UPDATE agent_runs SET state = 'running' WHERE id = ?`, first.ID,
		); err != nil {
			t.Fatal(err)
		}
		if err := st.StageAgentRunResult(
			ctx, first.ID, terminalState, []byte(`{"action":"reply"}`), "", 1,
		); err != nil {
			t.Fatal(err)
		}
		second, created, queueErr := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: first.ConversationKey,
			SourceKind: "recheck", SourceID: "newer-" + source, Prompt: "newer",
		})
		if queueErr != nil || !created {
			t.Fatalf("queue replacement = %+v, %t, %v", second, created, queueErr)
		}
		return first, second
	}

	failed, replacement := stage("older-failure", "failed")
	if _, err := st.LeaseAgentRunFinalization(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("lease stale finalization = %v", err)
	}
	stored, err := st.GetAgentRun(ctx, failed.ID)
	if err != nil || stored.State != core.AgentRunSuperseded {
		t.Fatalf("a replaced failure was still finalized: %+v, %v", stored, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil || leased.ID != replacement.ID {
		t.Fatalf("newer attempt = %+v, %v", leased, err)
	}

	answered, _ := stage("older-result", "completed")
	claimed, err := st.LeaseAgentRunFinalization(ctx)
	if err != nil {
		t.Fatalf("a finished answer was refused finalization: %v", err)
	}
	if claimed.ID != answered.ID {
		t.Fatalf("finalization claimed %q, want the finished answer %q", claimed.ID, answered.ID)
	}
	stored, err = st.GetAgentRun(ctx, answered.ID)
	if err != nil || stored.State != core.AgentRunFinalizing {
		t.Fatalf("the finished answer = %+v, %v", stored, err)
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
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "success-source", EnvelopeID: "env-success-source", Kind: "message",
		TeamID: "T1", ChannelID: "COPS", MessageTS: "1700.300",
		UserID: "U1", Text: "question", ReceivedAt: time.Now().UTC(),
	}); err != nil || !created {
		t.Fatalf("admit source = %t, %v", created, err)
	}
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
	if markers, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_failure_marker_add_"); err != nil || len(markers) != 0 {
		t.Fatalf("preserved success was marked failed: %+v, %v", markers, err)
	}
}

func TestRetryableProcessingFailureDoesNotMarkSource(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "input_retryable_marker", EnvelopeID: "env_retryable_marker",
		Kind: "message", TeamID: "T1", ChannelID: "COPS", MessageTS: "1700.301",
		UserID: "U1", Text: "question", ReceivedAt: time.Now().UTC(),
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit source = %t, %v", created, err)
	}
	run, _ := queueKernelEpisode(t, st, input.ID)
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if err := st.RetryAgentRun(ctx, run.ID, "temporary HTTP 500", time.Now().UTC(), false); err != nil {
		t.Fatal(err)
	}
	if markers, err := st.ListSlackDeliveriesByPrefix(ctx, "delivery_failure_marker_add_"); err != nil || len(markers) != 0 {
		t.Fatalf("retryable failure markers = %+v, %v", markers, err)
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
