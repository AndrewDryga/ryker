package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/replayinterrupt"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestAgentRunCancellationCheckReadsDurableStateAfterWorkerCancellation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_replay_cancel_race", EnvelopeID: "replay-private:cancel-race",
		EventID: "replay-private:cancel-race", Kind: "message", TeamID: "T1",
		ChannelID: "C1", MessageTS: "1700.001", UserID: "U1", Text: "check",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit replay = %t, %v", created, err)
	}
	if _, err := st.LeaseSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "1700.001",
		ConversationKey: "slack:C1:1700.001", SourceKind: "watch",
		SourceID: input.ID, UserID: "U1",
	})
	if err != nil || !created {
		t.Fatalf("queue run = %t, %v", created, err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	cancelledCtx, cancel := context.WithCancel(ctx)
	cancel()
	if svc.agentRunCancellationApplied(cancelledCtx, run.ID) {
		t.Fatal("ordinary worker cancellation was mistaken for a durable replay cancellation")
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunPending {
		t.Fatalf("run state = %s, want unchanged pending state", stored.State)
	}
}

type missingSubmitCoop struct{ *fakeCoop }

func (m missingSubmitCoop) OperationByKey(context.Context, string) (coop.Operation, error) {
	return coop.Operation{}, &coop.APIError{Status: 404, Code: "not_found"}
}

func TestPersistedReplayCancellationSettlesNoSubmitAfterRestartGrace(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	now := time.Now().UTC().Truncate(time.Second)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	st.SetClock(func() time.Time { return now })
	input := core.SlackInput{
		ID: "slack_replay_pre_submit", EnvelopeID: "replay-private:pre-submit",
		EventID: "replay-private:pre-submit", Kind: "message", TeamID: "T1",
		ChannelID: "C1", MessageTS: "1700.002", UserID: "U1", Text: "check",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if _, err := st.LeaseSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "1700.002",
		ConversationKey: "slack:C1:1700.002", SourceKind: "watch", SourceID: input.ID, UserID: "U1",
	})
	if err != nil || !created {
		t.Fatalf("queue = %t, %v", created, err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(ctx, run.ID, "ses_1", 1, "repo", 0, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	if _, applied, _, err := store.CancelSlackReplay(ctx, st, input.ID, run.IdempotencyKey, "timeout"); err != nil || !applied {
		t.Fatalf("cancel = %t, %v", applied, err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	st, err = store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	st.SetClock(func() time.Time { return now })
	svc := New(cfg, st, missingSubmitCoop{newFakeCoop()}, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.SetClock(func() time.Time { return now })
	if err := svc.runScheduledWork(ctx, store.WorkItem{Kind: workReplayCancel}); !errors.Is(err, replayinterrupt.ErrSubmitOperationNotFound) {
		t.Fatalf("first recovery = %v", err)
	}
	now = now.Add(3 * time.Minute)
	if err := svc.runScheduledWork(ctx, store.WorkItem{Kind: workReplayCancel}); err != nil {
		t.Fatalf("settled recovery = %v", err)
	}
	if _, err := st.ReplayCancellations.Next(ctx); !errors.Is(err, core.ErrNotFound) {
		t.Fatalf("remaining obligation = %v", err)
	}
}
