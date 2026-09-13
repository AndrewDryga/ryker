package service

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	episodepkg "github.com/AndrewDryga/ryker/internal/episode"
	"github.com/AndrewDryga/ryker/internal/investigation"
	"github.com/AndrewDryga/ryker/internal/store"
)

// A goal the episode never planned must not be able to withhold the answer
// beside it.
//
// This is the exact shape that stalled a finished engineering task in
// production: the agent committed its work, then closed goal
// "va1-traefik-oom-recurrence" without ever having opened it. The not-found
// from that one operation failed the whole result, and because operations
// apply in order and the dangling close sorted ahead of the complete_episode,
// the completion never applied. The turn was done and sound; the Slack card
// read "Investigating" for twenty-one minutes while the terminal poll — which
// has no failure counter and no backoff — replayed the same failure about
// three times a second.
//
// So the assertion that matters is not merely that this returns nil. It is
// that the operation *after* the dangling one still lands.
func TestDanglingGoalCloseDoesNotWithholdTheCompletionBesideIt(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{
		{
			ID: "goal-completed-never-planned", Type: "update_goal",
			GoalState: &investigation.GoalStateOperation{
				GoalID: "a-goal-nothing-ever-created",
				State:  core.GoalCompleted,
			},
		},
		{
			ID: "complete-the-episode", Type: "complete_episode",
			Completion: &investigation.CompleteEpisode{
				Message: "Committed as f804b18c.",
			},
		},
	}); err != nil {
		t.Fatalf("recording a result that closes an unplanned goal = %v, want nil", err)
	}

	events, err := st.ListWorkEpisodeEvents(ctx, run.ID, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range events {
		if event.Kind == episodepkg.EventCompletionSubmitted {
			return
		}
	}
	t.Fatalf(
		"the completion beside the dangling goal close was never recorded; got %d events: %v",
		len(events), episodeEventKinds(events),
	)
}

// A reused durable id costs its operation, not the turn — and not the queue.
//
// The kernel refuses a goal or wakeup id reused with different semantics, and
// that refusal is deterministic: re-applying the identical result can only be
// refused the identical way. It used to escape this seam to the poll loop,
// which re-read the same completed turn every fifteen seconds forever. One
// wakeup-id reuse held the emisar deployment's queue for eleven hours and 650
// watchdog strikes; one goal-id reuse held a blitz channel for 80 minutes —
// both with a finished, staged answer that never reached Slack, behind runs
// serialized on the wedged one. The recorded id keeps its original semantics;
// the reuse drops with a trace, and the completion beside it still lands.
func TestAReusedWakeupIdCostsItsOperationNotTheTurn(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{{
		ID: "wait-target-run", Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: "wakeup-1", Kind: "terraform_run",
			PollAfter: time.Now().UTC().Add(time.Minute).Format(time.RFC3339),
			Deadline:  time.Now().UTC().Add(time.Hour).Format(time.RFC3339),
		},
	}}); err != nil {
		t.Fatalf("recording the original wait = %v, want nil", err)
	}

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{
		{
			ID: "wait-target-run-again", Type: "wait_external",
			ExternalWait: &investigation.ExternalWaitOperation{
				ID: "wakeup-1", Kind: "deployment",
				PollAfter: time.Now().UTC().Add(time.Minute).Format(time.RFC3339),
				Deadline:  time.Now().UTC().Add(time.Hour).Format(time.RFC3339),
			},
		},
		{
			ID: "complete-the-episode", Type: "complete_episode",
			Completion: &investigation.CompleteEpisode{
				Message: "The run errored; diagnostics are in the thread.",
			},
		},
	}); err != nil {
		t.Fatalf("a reused wakeup id failed the whole result = %v, want nil", err)
	}

	events, err := st.ListWorkEpisodeEvents(ctx, run.ID, 100)
	if err != nil {
		t.Fatal(err)
	}
	dropped, completed := false, false
	for _, event := range events {
		switch event.Kind {
		case episodepkg.EventOperationDropped:
			dropped = true
		case episodepkg.EventCompletionSubmitted:
			completed = true
		}
	}
	if !completed {
		t.Fatalf(
			"the completion beside the reused wakeup id was never recorded; got %v",
			episodeEventKinds(events),
		)
	}
	if !dropped {
		t.Fatalf(
			"the reused wakeup id was dropped without a trace; got %v",
			episodeEventKinds(events),
		)
	}
}

func TestScheduledVerificationKeepsItsObservableSuccessCheck(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)
	verification := "all eight routed services are healthy after the rollout"
	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{{
		ID: "wait-rollout-health", Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: "verify-rollout-health", Kind: "scheduled_verification",
			Verification: verification,
			EventMatcher: []byte(`{"provider":"hcp_terraform","run_id":"run-abc"}`),
			PollAfter:    time.Now().UTC().Add(time.Minute).Format(time.RFC3339),
			Deadline:     time.Now().UTC().Add(time.Hour).Format(time.RFC3339),
		},
	}}); err != nil {
		t.Fatal(err)
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, run.EpisodeID)
	if err != nil || len(wakeups) != 1 {
		t.Fatalf("scheduled wakeups = %+v, %v", wakeups, err)
	}
	if wakeups[0].Verification != verification {
		t.Fatalf("scheduled verification lost its success check: %+v", wakeups[0])
	}
}

// Four Terraform episodes on 2026-08-18 finished in waiting_external after
// their model reused the wakeup ID that had just resumed the turn. The store
// correctly returned the already-resolved row, but finalization trusted the
// proposed operation and left each episode parked with no clock behind it.
func TestAResolvedWakeupIdentityCannotLeaveAnEpisodeWaitingWithoutAClock(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)
	now := time.Now().UTC()
	wakeup, err := st.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
		ID: "terraform-run-terminal", EpisodeID: run.EpisodeID, Kind: "terraform_run",
		Verification: "verify the rollout after the exact run becomes terminal",
		EventMatcher: []byte(`{"provider":"hcp_terraform","run_id":"run-abc"}`),
		PollAfter:    now.Add(-time.Second), Deadline: now.Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseDueEpisodeWakeup(ctx, "test-worker", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.ResolveEpisodeWakeup(
		ctx, leased.ID, "test-worker", leased.FencingToken, []byte(`{"state":"planning"}`),
	); err != nil {
		t.Fatal(err)
	}
	operation := investigation.ResultOperation{
		ID: "wait-again", Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: wakeup.ID, Kind: wakeup.Kind, Verification: wakeup.Verification,
			EventMatcher: wakeup.EventMatcher,
			PollAfter:    now.Add(time.Minute).Format(time.RFC3339),
			Deadline:     now.Add(time.Hour).Format(time.RFC3339),
		},
	}

	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	correction, err := svc.episodeClaimCorrectionWithHistory(
		ctx, episode, "silence", nil, nil, nil, now, run.StartedAt,
		[]investigation.ResultOperation{operation}, nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(correction, "already resolved") ||
		!strings.Contains(correction, "fresh external_wait.id") {
		t.Fatalf("correction = %q", correction)
	}
	operation.ExternalWait.ID = "terraform-run-terminal-refresh"
	if correction, err := svc.episodeClaimCorrectionWithHistory(
		ctx, episode, "silence", nil, nil, nil, now, run.StartedAt,
		[]investigation.ResultOperation{operation}, nil,
	); err != nil || correction != "" {
		t.Fatalf("fresh wakeup correction = %q, %v", correction, err)
	}
}

// Three confirmable Terraform plans each started a two-minute model-powered
// terminal-refresh loop on 2026-08-17. By refresh nine the state was still the
// same human approval wait, and the loops were consuming the provider quota
// that real Slack work needed. Lifecycle cards remain the fast path; the host
// poll is a fallback and must not run more than once per ten minutes.
func TestTerraformWaitCannotPollMoreThanOncePerTenMinutes(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)
	now := time.Date(2026, 8, 18, 4, 30, 0, 0, time.UTC)
	svc.SetClock(func() time.Time { return now })
	deadline := now.Add(2 * time.Hour)
	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{{
		ID: "wait-terminal-refresh", Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: "wakeup-terminal-refresh", Kind: "terraform_run",
			Verification: "verify the exact run after its terminal result",
			EventMatcher: []byte(`{"provider":"hcp_terraform","run_id":"run-abc"}`),
			PollAfter:    now.Add(2 * time.Minute).Format(time.RFC3339),
			Deadline:     deadline.Format(time.RFC3339),
		},
	}}); err != nil {
		t.Fatal(err)
	}
	wakeups, err := st.ListEpisodeWakeups(ctx, run.EpisodeID)
	if err != nil || len(wakeups) != 1 {
		t.Fatalf("Terraform wakeups = %+v, %v", wakeups, err)
	}
	if want := now.Add(10 * time.Minute); !wakeups[0].PollAfter.Equal(want) {
		t.Fatalf("Terraform fallback poll = %s, want %s", wakeups[0].PollAfter, want)
	}
	if !wakeups[0].Deadline.Equal(deadline) {
		t.Fatalf("Terraform deadline changed = %s, want %s", wakeups[0].Deadline, deadline)
	}
}

// One planned-and-saved Terraform run produced 112 model turns in five hours
// on 2026-08-18. Every turn called the same run, found it still awaiting human
// confirmation, and moved its supposedly bounded deadline forward another
// twenty minutes. A deadline bounds the external wait chain, not one row in it.
func TestTerraformWaitChainCannotRenewItsOriginalDeadline(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)
	now := time.Now().UTC()
	originalDeadline := now.Add(30 * time.Minute)
	first, err := st.CreateEpisodeWakeup(ctx, core.EpisodeWakeup{
		ID: "terraform-run-abc-terminal", EpisodeID: run.EpisodeID, Kind: "terraform_run",
		Verification: "verify the exact run after apply",
		EventMatcher: []byte(`{"provider":"hcp_terraform","run_id":"run-abc"}`),
		PollAfter:    now.Add(-time.Second), Deadline: originalDeadline,
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseDueEpisodeWakeup(ctx, "test-worker", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.ResolveEpisodeWakeup(
		ctx, leased.ID, "test-worker", leased.FencingToken, []byte(`{"state":"planned_and_saved"}`),
	); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	operation := investigation.ResultOperation{
		ID: "wait-refresh", Type: "wait_external",
		ExternalWait: &investigation.ExternalWaitOperation{
			ID: first.ID + "-refresh", Kind: first.Kind, Verification: first.Verification,
			EventMatcher: first.EventMatcher,
			PollAfter:    now.Add(20 * time.Minute).Format(time.RFC3339),
			Deadline:     now.Add(time.Hour).Format(time.RFC3339),
		},
	}

	correction, err := svc.episodeClaimCorrectionWithHistory(
		ctx, episode, "silence", nil, nil, nil, now, run.StartedAt,
		[]investigation.ResultOperation{operation}, nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(correction, "original Terraform wait deadline") ||
		!strings.Contains(correction, originalDeadline.Format(time.RFC3339)) {
		t.Fatalf("renewed deadline correction = %q", correction)
	}

	operation.ExternalWait.Deadline = originalDeadline.Format(time.RFC3339)
	if correction, err := svc.episodeClaimCorrectionWithHistory(
		ctx, episode, "silence", nil, nil, nil, now, run.StartedAt,
		[]investigation.ResultOperation{operation}, nil,
	); err != nil || correction != "" {
		t.Fatalf("bounded refresh correction = %q, %v", correction, err)
	}
	if correction, err := svc.episodeClaimCorrectionWithHistory(
		ctx, episode, "silence", nil, nil, nil,
		originalDeadline.Add(time.Second), run.StartedAt,
		[]investigation.ResultOperation{operation}, nil,
	); err != nil || !strings.Contains(correction, "has elapsed") {
		t.Fatalf("elapsed deadline correction = %q, %v", correction, err)
	}
}

// The prerequisite variant of the same wedge, caught live the same evening the
// wakeup variant was fixed: run_dba732ef poll-looped on `goal prerequisite
// "goal-impact" is not in episode` — a plan_goal referencing a goal the model
// never planned — with four runs serialized behind it. Every deterministic
// kernel rejection of a result operation is the same disease and takes the
// same cure: the operation drops with a trace, the completion beside it lands.
func TestADanglingGoalPrerequisiteCostsItsOperationNotTheTurn(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{
		{
			ID: "goal-plan-cause", Type: "plan_goal",
			Goal: &investigation.GoalOperation{
				ID: "goal-cause", Kind: "check",
				RequestedOutcome:    "Name the cause",
				CompletionContract:  "A cause is named and evidenced",
				Required:            true,
				PrerequisiteGoalIDs: []string{"goal-impact"},
				Authority:           core.AuthorityReadOnly,
			},
		},
		{
			ID: "complete-the-episode", Type: "complete_episode",
			Completion: &investigation.CompleteEpisode{
				Message: "Impact is bounded; cause identified in the thread.",
			},
		},
	}); err != nil {
		t.Fatalf("a dangling goal prerequisite failed the whole result = %v, want nil", err)
	}

	events, err := st.ListWorkEpisodeEvents(ctx, run.ID, 100)
	if err != nil {
		t.Fatal(err)
	}
	dropped, completed := false, false
	for _, event := range events {
		switch event.Kind {
		case episodepkg.EventOperationDropped:
			dropped = true
		case episodepkg.EventCompletionSubmitted:
			completed = true
		}
	}
	if !completed {
		t.Fatalf("the completion beside the dangling prerequisite was never recorded; got %v",
			episodeEventKinds(events))
	}
	if !dropped {
		t.Fatalf("the dangling prerequisite was dropped without a trace; got %v",
			episodeEventKinds(events))
	}
}

// A goal that was planned still closes. The tolerance above is for a reference
// to nothing, not a licence to drop bookkeeping that has somewhere to land.
func TestPlannedGoalStillClosesFromAResultOperation(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreateEpisodeGoal(ctx, core.EpisodeGoal{
		ID: "goal-1", EpisodeID: episode.ID, Kind: "investigate",
		RequestedOutcome:     "Find why the alert fired",
		CompletionContract:   "A cause is named and evidenced",
		Required:             true,
		AuthorityRequirement: core.AuthorityReadOnly,
	}); err != nil {
		t.Fatal(err)
	}

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{{
		ID: "goal-completed-1", Type: "update_goal",
		GoalState: &investigation.GoalStateOperation{
			GoalID: "goal-1", State: core.GoalCompleted,
		},
	}}); err != nil {
		t.Fatal(err)
	}

	events, err := st.ListEpisodeEvents(ctx, episode.ID, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range events {
		if event.Kind == episodepkg.EventGoalCompleted {
			return
		}
	}
	t.Fatalf(
		"closing a planned goal recorded no completion; got %v",
		episodeEventKinds(events),
	)
}

func episodeEventKinds(events []core.WorkEpisodeEvent) []string {
	kinds := make([]string, 0, len(events))
	for _, event := range events {
		kinds = append(kinds, event.Kind)
	}
	return kinds
}

func hasEpisodeEvent(events []core.WorkEpisodeEvent, kind string) bool {
	for _, event := range events {
		if event.Kind == kind {
			return true
		}
	}
	return false
}

// An unparseable timestamp is the other shape of the same defect: bytes the
// model produced that no amount of retrying will re-parse. It must be dropped
// like a dangling reference rather than fail the result around it.
func TestUnparseableOperationTimestampDoesNotWithholdTheCompletion(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{
		{
			ID: "progress-with-bad-due", Type: "report_progress",
			Progress: &investigation.ProgressOperation{
				Phase: "investigating", Summary: "Still reading the jobspec.",
				NextDueAt: "in about five minutes",
			},
		},
		{
			ID: "complete-the-episode", Type: "complete_episode",
			Completion: &investigation.CompleteEpisode{Message: "Done."},
		},
	}); err != nil {
		t.Fatalf("recording a result with an unparseable due date = %v, want nil", err)
	}

	events, err := st.ListWorkEpisodeEvents(ctx, run.ID, 100)
	if err != nil {
		t.Fatal(err)
	}
	if !hasEpisodeEvent(events, episodepkg.EventCompletionSubmitted) {
		t.Fatalf("completion was withheld; got %v", episodeEventKinds(events))
	}
}

// A dropped operation has to leave a trace. Silently discarding what the model
// asked for would trade one invisible failure for another: the operator asking
// why a goal never closed needs the answer in the episode's own timeline.
func TestADroppedOperationIsRecordedOnTheEpisode(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{{
		ID: "goal-completed-never-planned", Type: "update_goal",
		GoalState: &investigation.GoalStateOperation{
			GoalID: "a-goal-nothing-ever-created", State: core.GoalCompleted,
		},
	}}); err != nil {
		t.Fatal(err)
	}

	events, err := st.ListWorkEpisodeEvents(ctx, run.ID, 100)
	if err != nil {
		t.Fatal(err)
	}
	if !hasEpisodeEvent(events, episodepkg.EventOperationDropped) {
		t.Fatalf("the drop left no trace on the episode; got %v", episodeEventKinds(events))
	}
}

// The tolerance is for operations that cannot ever apply, not for a database
// that is briefly unavailable. Getting this line wrong in the permissive
// direction is the expensive mistake: it would drop real work on a transient
// error and report success, which is worse than the stall this fix removes.
func TestOnlyFailuresRetryingCannotFixAreTreatedAsUnappliable(t *testing.T) {
	_, parseErr := time.Parse(time.RFC3339, "in about five minutes")
	if parseErr == nil {
		t.Fatal("expected a parse error to build the case with")
	}
	for _, testCase := range []struct {
		name string
		err  error
		want bool
	}{
		{"a reference to nothing", store.ErrNotFound, true},
		{"a wrapped reference to nothing",
			fmt.Errorf("result operation %q: %w", "goal-1", store.ErrNotFound), true},
		{"bytes that do not parse", parseErr, true},
		{"a wrapped parse failure",
			fmt.Errorf("result operation %q due_at: %w", "wait-1", parseErr), true},
		{"a locked database", errors.New("database is locked"), false},
		{"a closed connection", sql.ErrConnDone, false},
		{"a cancelled context", context.Canceled, false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if got := unappliableOperation(testCase.err); got != testCase.want {
				t.Fatalf("unappliableOperation(%v) = %t, want %t",
					testCase.err, got, testCase.want)
			}
		})
	}
}

// An infrastructure failure must still reach the caller, because the poll that
// retries it is the only thing standing between a blip and a lost answer.
func TestAnInfrastructureFailureStillFailsTheResult(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)
	st.Close()

	err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{{
		ID: "complete-the-episode", Type: "complete_episode",
		Completion: &investigation.CompleteEpisode{Message: "Done."},
	}})
	if err == nil {
		t.Fatal("a closed database recorded a result without error, want the failure to propagate")
	}
}

// A discovered failure lands on the episode's own timeline, beside the evidence
// it was found in.
//
// The record is what makes "did anyone ever explain this" a question the trace
// can answer. On 2026-08-11 the 12:16 Zot triage
// (episode_run_ebbee0227d72743cc4aee48ef01113ba) recorded two evidence rows for
// a VA1 rollout that had failed, and recorded the failure itself nowhere: it was
// a sentence in a Slack message, so reconstructing what the episode had actually
// found meant reading the thread. Three human nudges and 88 minutes later a deep
// dive found the root cause in four.
func TestARecordedFindingReachesTheEpisodeTimeline(t *testing.T) {
	ctx, st, svc, _, run := activityRunFixture(t)

	if err := svc.recordResultOperationEvents(ctx, run.ID, []investigation.ResultOperation{{
		ID: "finding-va1", Type: "record_finding",
		Finding: &investigation.FindingOperation{
			What:  "VA1 pyke did not deploy; its rollout missed the progress deadline",
			Scope: "va1-apps", Status: "unexplained",
		},
	}}); err != nil {
		t.Fatalf("recording a finding = %v, want nil", err)
	}

	events, err := st.ListWorkEpisodeEvents(ctx, run.ID, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range events {
		if event.Kind != episodepkg.EventFindingRecorded {
			continue
		}
		if !strings.Contains(string(event.Payload), "missed the progress deadline") {
			t.Fatalf("the finding event does not carry what failed: %s", event.Payload)
		}
		return
	}
	t.Fatalf("no %s event; the discovered failure is on the record nowhere: %+v",
		episodepkg.EventFindingRecorded, events)
}
