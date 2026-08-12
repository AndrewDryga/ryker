package service

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/retrydelay"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The waiting interval keeps the handoff a queued run had, and stops the
// once-a-second transaction that filled both write-ahead logs.
func TestDependencyWaitDelayHoldsTheFloorThenBacksOffToACap(t *testing.T) {
	for _, testCase := range []struct {
		waited time.Duration
		want   time.Duration
	}{
		// A run that has only just been queued polls exactly as it always did.
		{waited: 0, want: time.Second},
		{waited: 4 * time.Second, want: time.Second},
		{waited: 8 * time.Second, want: time.Second},
		// Past the floor the interval is an eighth of the wait so far, so the
		// added latency stays proportional to a wait that is already long.
		{waited: 16 * time.Second, want: 2 * time.Second},
		{waited: time.Minute, want: 7500 * time.Millisecond},
		// Two minutes in, the cap. Fifteen seconds is the worst case this can
		// add to any handoff.
		{waited: 2 * time.Minute, want: 15 * time.Second},
		{waited: time.Hour, want: 15 * time.Second},
		// A clock that disagrees with a stored timestamp must not produce a
		// delay in the past, which would restore the once-a-second loop.
		{waited: -time.Hour, want: time.Second},
	} {
		if got := retrydelay.DependencyWait(testCase.waited); got != testCase.want {
			t.Errorf("DependencyWait(%s) = %s, want %s", testCase.waited, got, testCase.want)
		}
	}
}

// deferredRunBehindBusyChannel queues one watch run, holds its Slack channel's
// Coop session busy, and returns how far out the run was rescheduled.
func deferredRunBehindBusyChannel(t *testing.T, queuedAgo time.Duration) time.Duration {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.ActiveTurnID = "coop_turn_busy"
	coopClient.session.Activity = "working"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	input := core.SlackInput{
		ID: "queued-behind", EnvelopeID: "queued-behind-envelope",
		EventID: "queued-behind-event", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.200", UserID: "U123ABC",
		Text: "<@UBOT> is CI green?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	// Move the clock forward rather than the row back: the delay is derived
	// from how long the run has been queued, so this is the one input.
	now := run.CreatedAt.Add(queuedAgo)
	svc.SetClock(func() time.Time { return now })

	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	deferred, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if deferred.State != core.AgentRunPending {
		t.Fatalf("run behind a busy channel = %s, want pending", deferred.State)
	}
	if deferred.LastError != "waiting for the previous agent run in this Slack channel" {
		t.Fatalf("run was not deferred for the reason under test: %q", deferred.LastError)
	}
	return deferred.NextAttemptAt.Sub(now)
}

// The wiring, not just the arithmetic: the interval has to come from how long
// this run has been queued. Reading the wall clock instead would give every
// poll the same delay again.
func TestRunBehindABusyChannelBacksOffTheLongerItWaits(t *testing.T) {
	if delay := deferredRunBehindBusyChannel(t, 0); delay != time.Second {
		t.Fatalf("a freshly queued run was rescheduled %s out, want 1s", delay)
	}
	if delay := deferredRunBehindBusyChannel(t, 10*time.Minute); delay != 15*time.Second {
		t.Fatalf("a run waiting ten minutes was rescheduled %s out, want 15s", delay)
	}
}
