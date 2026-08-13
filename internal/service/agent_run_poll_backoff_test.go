package service

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// A poll that keeps failing must stop retrying at full speed.
//
// The production shape: one finished result carried an operation the host could
// not apply, the poll returned that error, and because the failure left the run
// running with its event cursor unadvanced, the next tick read the same events
// and failed identically. Nothing counted the failures, nothing slowed them
// down, and nothing gave up — 23,030 identical warnings over seventy-nine
// minutes, roughly three every second, while the scheduler queue drained
// normally and every health signal read green.
//
// The three assertions below are the three things that were missing: the
// failure is written down, the next poll is held off, and the hold expires.
func TestAFailingPollIsHeldOffInsteadOfRetryingAtFullSpeed(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	base := time.Now().UTC()
	svc.clock = func() time.Time { return base }
	coopClient.eventsErr = errors.New("coop is unreachable")

	svc.pollAgentRuns(ctx)

	held, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(held.LastError, "coop is unreachable") {
		t.Fatalf("last error = %q, want the cause recorded on the run", held.LastError)
	}
	if !held.NextAttemptAt.After(base) {
		t.Fatalf("next attempt = %s, want a hold-off after %s", held.NextAttemptAt, base)
	}
	if held.State != core.AgentRunRunning {
		t.Fatalf("state = %q, want the run left running", held.State)
	}

	// A poll inside the hold-off window must not reach Coop at all. This is the
	// assertion that actually distinguishes the fix from the bug: without it the
	// loop is still spinning, just with a tidier error.
	callsAfterFirst := coopClient.eventsCalls
	svc.pollAgentRuns(ctx)
	if coopClient.eventsCalls != callsAfterFirst {
		t.Fatalf(
			"Coop was polled %d more times inside the hold-off window, want 0",
			coopClient.eventsCalls-callsAfterFirst,
		)
	}

	// And the hold must be a delay, not a death sentence: a transient failure
	// resolves, and the run has to be there to notice.
	svc.clock = func() time.Time { return held.NextAttemptAt.Add(time.Second) }
	coopClient.eventsErr = nil
	svc.pollAgentRuns(ctx)
	if coopClient.eventsCalls <= callsAfterFirst {
		t.Fatal("the poll never resumed after the hold-off expired")
	}
}

// A failure the poll recovered from must not be left lying on the run.
//
// stalledRunDetail reads last_error to tell an operator why work stopped, so a
// resolved error still sitting there would be offered as the cause of some
// later, unrelated silence — a confident wrong answer, which is worse than the
// generic one it replaced.
func TestARecoveredPollClearsTheFailureItRecorded(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	base := time.Now().UTC()
	svc.clock = func() time.Time { return base }
	coopClient.eventsErr = errors.New("coop is unreachable")
	svc.pollAgentRuns(ctx)

	held, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if held.LastError == "" {
		t.Fatal("the failing poll recorded nothing to recover from")
	}

	coopClient.eventsErr = nil
	svc.clock = func() time.Time { return held.NextAttemptAt.Add(time.Second) }
	svc.pollAgentRuns(ctx)

	recovered, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if recovered.LastError != "" {
		t.Fatalf("last error = %q after the poll recovered, want it cleared", recovered.LastError)
	}
}

// The hold-off has to cover the incident path too. pollIncident polls the same
// run through the incident's active turn, which is why the outage produced two
// warnings per pass rather than one; a guard in pollAgentRuns alone would have
// throttled half of it and left the other half spinning.
func TestTheHoldOffAlsoCoversTheIncidentPollPath(t *testing.T) {
	ctx, _, svc, coopClient, run := activityRunFixture(t)
	base := time.Now().UTC()
	svc.clock = func() time.Time { return base }
	coopClient.eventsErr = errors.New("coop is unreachable")

	svc.pollAgentRuns(ctx)
	callsAfterFirst := coopClient.eventsCalls

	held, err := svc.store.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.pollAgentRun(ctx, held); err != nil {
		t.Fatalf("a held-off run reported %v, want it skipped silently", err)
	}
	if coopClient.eventsCalls != callsAfterFirst {
		t.Fatalf(
			"the incident path polled Coop %d more times inside the hold-off window, want 0",
			coopClient.eventsCalls-callsAfterFirst,
		)
	}
}

// The delay grows with how long the run has been going nowhere. Measuring from
// the run's start rather than its last write is what makes that true: the
// hold-off writes to the row every time it fires, so a backoff clocked from
// updated_at would reset itself on every failure and never actually back off.
func TestTheHoldOffGrowsWithHowLongTheRunHasBeenStuck(t *testing.T) {
	ctx, st, svc, coopClient, run := activityRunFixture(t)
	coopClient.eventsErr = errors.New("coop is unreachable")

	started, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}

	delayAfter := func(stuck time.Duration) time.Duration {
		at := started.StartedAt.Add(stuck)
		svc.clock = func() time.Time { return at }
		// Clear any live hold so this poll is the one that sets it.
		if err := st.HoldOffAgentRunPoll(ctx, run.ID, "", at.Add(-time.Second)); err != nil {
			t.Fatal(err)
		}
		svc.pollAgentRuns(ctx)
		held, err := st.GetAgentRun(ctx, run.ID)
		if err != nil {
			t.Fatal(err)
		}
		return held.NextAttemptAt.Sub(at)
	}

	brief, long := delayAfter(time.Second), delayAfter(30*time.Minute)
	if brief >= long {
		t.Fatalf("delay after a moment = %s, after half an hour = %s; want it to grow", brief, long)
	}
	if long > 15*time.Second {
		t.Fatalf("delay = %s, want it bounded at the fifteen second ceiling", long)
	}
}
