package service

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/store"
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
