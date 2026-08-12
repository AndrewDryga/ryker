package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestCancelSlackReplayAtomicallyRetiresActiveWorkAndOutbox(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_replay_cancel", EnvelopeID: "replay-private:slack_replay_cancel",
		EventID: "replay-private:slack_replay_cancel", Kind: "message", TeamID: "T1",
		ChannelID: "C1", MessageTS: "1700.001", UserID: "U1", Text: "check",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit replay = %t, %v", created, err)
	}
	if _, err := st.LeaseSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "slack:C1:1700.001", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID,
	})
	if err != nil || !created {
		t.Fatalf("queue replay = %t, %v", created, err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + input.ID, EpisodeID: run.EpisodeID, AgentRunID: run.ID,
		AgentRunKey: run.IdempotencyKey, Operation: "post", Kind: "assistant",
		ChannelID: input.ChannelID, ThreadTS: input.MessageTS, Body: []byte(`{"text":"late"}`),
		ResponseRoot: true,
	}); err != nil || !created {
		t.Fatalf("enqueue replay result = %t, %v", created, err)
	}

	cancelled, applied, uncertain, err := CancelSlackReplay(ctx, st, input.ID, run.IdempotencyKey, "CLI deadline expired")
	if err != nil || !applied || uncertain || cancelled.ID != run.ID {
		t.Fatalf("cancel replay = %+v, applied=%t uncertain=%t err=%v", cancelled, applied, uncertain, err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunCancelled {
		t.Fatalf("run after cancel = %+v, %v", stored, err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil || episode.State != core.EpisodeCancelled {
		t.Fatalf("episode after cancel = %+v, %v", episode, err)
	}
	attempt, err := st.GetEpisodeAttempt(ctx, run.AttemptID)
	if err != nil || attempt.State != core.AttemptCancelled {
		t.Fatalf("attempt after cancel = %+v, %v", attempt, err)
	}
	storedInput, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || storedInput.State != "done" {
		t.Fatalf("input after cancel = %+v, %v", storedInput, err)
	}
	delivery, err := st.GetSlackDelivery(ctx, "watch_reply_"+input.ID)
	if err != nil || delivery.State != "superseded" {
		t.Fatalf("delivery after cancel = %+v, %v", delivery, err)
	}
	if _, applied, _, err := CancelSlackReplay(ctx, st, input.ID, run.IdempotencyKey, "again"); err != nil || applied {
		t.Fatalf("second cancel = applied %t, %v", applied, err)
	}
}

func TestCancelSlackReplayRefusesARequeuedExecutionGeneration(t *testing.T) {
	ctx := context.Background()
	st, input, run := queuedReplayForCancellation(t, ctx)
	defer st.Close()
	if err := st.RetryAgentRun(ctx, run.ID, "first execution failed", time.Now().UTC(), true); err != nil {
		t.Fatal(err)
	}
	if err := st.RequeueFailedAgentRun(ctx, run.ID, "operator retried"); err != nil {
		t.Fatal(err)
	}
	requeued, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if requeued.IdempotencyKey == run.IdempotencyKey {
		t.Fatal("retry did not rotate the execution key")
	}
	if _, _, _, err := CancelSlackReplay(
		ctx, st, input.ID, run.IdempotencyKey, "late timeout",
	); !errors.Is(err, ErrConflict) {
		t.Fatalf("late generation cancellation = %v, want conflict", err)
	}
	current, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || current.State != core.AgentRunPending || current.IdempotencyKey != requeued.IdempotencyKey {
		t.Fatalf("requeued generation changed = %+v, %v", current, err)
	}
}

func TestCancelSlackReplayRetiresItsStaleEpisodeAttemptOnly(t *testing.T) {
	ctx := context.Background()
	st, input, first := queuedReplayForCancellation(t, ctx)
	defer st.Close()
	if _, err := st.db.ExecContext(ctx, `UPDATE agent_runs SET state = 'running' WHERE id = ?`, first.ID); err != nil {
		t.Fatal(err)
	}
	second, created, err := st.QueueEpisodeAttempt(ctx, first.EpisodeID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
		ConversationKey: first.ConversationKey, SourceKind: "watch",
		SourceID: "newer-replay-attempt", Prompt: "newer",
	})
	if err != nil || !created {
		t.Fatalf("queue newer attempt = %t, %v", created, err)
	}
	cancelled, applied, _, err := CancelSlackReplay(
		ctx, st, input.ID, first.IdempotencyKey, "CLI deadline expired",
	)
	if err != nil || !applied || cancelled.State != core.AgentRunCancelled {
		t.Fatalf("cancel stale attempt = %+v applied=%t err=%v", cancelled, applied, err)
	}
	current, err := st.GetWorkEpisode(ctx, first.EpisodeID)
	if err != nil || current.LatestAttemptID != second.AttemptID || current.State == core.EpisodeCancelled {
		t.Fatalf("newer episode ownership changed = %+v, %v", current, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil || leased.ID != second.ID {
		t.Fatalf("newer attempt lease = %+v, %v", leased, err)
	}
}

func TestCancelSlackReplayBeforeQueuePreventsLateAdmission(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_replay_before_queue", EnvelopeID: "replay-private:slack_replay_before_queue",
		EventID: "replay-private:slack_replay_before_queue", Kind: "message", TeamID: "T1",
		ChannelID: "C1", MessageTS: "1700.002", UserID: "U1", Text: "check",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit replay = %t, %v", created, err)
	}
	if _, applied, _, err := CancelSlackReplay(ctx, st, input.ID, "", "CLI deadline expired"); err != nil || !applied {
		t.Fatalf("cancel before queue = %t, %v", applied, err)
	}
	_, _, err = st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "slack:C1:1700.002", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID,
	})
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("late queue error = %v, want conflict", err)
	}
}

func TestCancelCompletedReplayStillSupersedesPendingOutput(t *testing.T) {
	ctx := context.Background()
	st, input, run := queuedReplayForCancellation(t, ctx)
	defer st.Close()
	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + input.ID, EpisodeID: run.EpisodeID,
		AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey,
		Operation: "post", Kind: "assistant", ChannelID: input.ChannelID,
		ThreadTS: input.MessageTS, Body: []byte(`{"text":"late"}`), ResponseRoot: true,
	}); err != nil || !created {
		t.Fatalf("enqueue reply = %t, %v", created, err)
	}
	finishReplayRunForCancellation(t, ctx, st, run)
	stored, applied, uncertain, err := CancelSlackReplay(ctx, st, input.ID, run.IdempotencyKey, "CLI deadline expired")
	if err != nil || applied || uncertain || stored.State != core.AgentRunCompleted {
		t.Fatalf("cancel completed replay = %+v applied=%t uncertain=%t err=%v", stored, applied, uncertain, err)
	}
	delivery, err := st.GetSlackDelivery(ctx, "watch_reply_"+input.ID)
	if err != nil || delivery.State != "superseded" {
		t.Fatalf("completed replay delivery = %+v err=%v", delivery, err)
	}
}

func TestCancelReplayMarksLeasedSlackOutputUncertain(t *testing.T) {
	ctx := context.Background()
	st, input, run := queuedReplayForCancellation(t, ctx)
	defer st.Close()
	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + input.ID, EpisodeID: run.EpisodeID,
		AgentRunID: run.ID, AgentRunKey: run.IdempotencyKey,
		Operation: "post", Kind: "assistant", ChannelID: input.ChannelID,
		ThreadTS: input.MessageTS, Body: []byte(`{"text":"in flight"}`), ResponseRoot: true,
	}); err != nil || !created {
		t.Fatalf("enqueue reply = %t, %v", created, err)
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	_, applied, uncertain, err := CancelSlackReplay(ctx, st, input.ID, run.IdempotencyKey, "CLI deadline expired")
	if err != nil || !applied || !uncertain {
		t.Fatalf("cancel with leased output = applied=%t uncertain=%t err=%v", applied, uncertain, err)
	}
	delivery, err := st.GetSlackDelivery(ctx, "watch_reply_"+input.ID)
	if err != nil || delivery.State != "uncertain" {
		t.Fatalf("leased replay delivery = %+v err=%v", delivery, err)
	}
	_, applied, uncertain, err = CancelSlackReplay(ctx, st, input.ID, run.IdempotencyKey, "retry cancellation")
	if err != nil || applied || !uncertain {
		t.Fatalf("repeat uncertain cancellation = applied=%t uncertain=%t err=%v", applied, uncertain, err)
	}
}

func queuedReplayForCancellation(
	t *testing.T,
	ctx context.Context,
) (*Store, core.SlackInput, core.AgentRun) {
	t.Helper()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack_replay_" + t.Name(), EnvelopeID: "replay-private:" + t.Name(),
		EventID: "replay-private:" + t.Name(), Kind: "message", TeamID: "T1",
		ChannelID: "C1", MessageTS: "1700.010", UserID: "U1", Text: "check",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit replay = %t, %v", created, err)
	}
	if _, err := st.LeaseSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.MessageTS,
		ConversationKey: "slack:C1:1700.010", SourceKind: "watch", SourceID: input.ID,
		UserID: input.UserID,
	})
	if err != nil || !created {
		t.Fatalf("queue replay = %t, %v", created, err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	return st, input, run
}

func finishReplayRunForCancellation(t *testing.T, ctx context.Context, st *Store, run core.AgentRun) {
	t.Helper()
	if err := st.BindAgentRunSession(ctx, run.ID, "ses_1", 1, "repo", 0, run.Context); err != nil {
		t.Fatal(err)
	}
	if _, err := st.FreezeAgentRunRevision(ctx, run.ID, 1); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, run.ID, "turn_1", 2, 0); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, run.ID, "completed", nil, "", 0); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishAgentRun(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
}
