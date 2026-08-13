package service

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/investigation"
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
