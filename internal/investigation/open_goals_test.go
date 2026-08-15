package investigation

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// The invariant the kernel enforces at finalization has to reach the model as
// a correction, or a sound completion loops on a store error forever:
// run_dab83e5b, forty finalization attempts over three hours on 2026-08-15,
// against a required goal one of its own turns had planned.
func TestACompletionThatLeavesARequiredGoalOpenIsCorrectedNotDeferred(t *testing.T) {
	goals := []core.EpisodeGoal{
		{ID: "goal-traffic", Required: true, State: core.GoalPlanned,
			RequestedOutcome: "Verify actual VA1 network and storage load"},
		{ID: "goal-optional", Required: false, State: core.GoalPlanned,
			RequestedOutcome: "Nice to have"},
		{ID: "goal-done", Required: true, State: core.GoalCompleted,
			RequestedOutcome: "Already closed"},
	}
	done := &CompletionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "bond0 is healthy"}

	correction := OpenRequiredGoalCorrection(goals, nil, done)
	if !strings.Contains(correction, "goal-traffic") ||
		!strings.Contains(correction, "Verify actual VA1 network and storage load") {
		t.Fatalf("an open required goal was not named: %q", correction)
	}
	if strings.Contains(correction, "goal-optional") || strings.Contains(correction, "goal-done") {
		t.Fatalf("an optional or closed goal was reported as open: %q", correction)
	}
	if !strings.Contains(correction, "update_goal") || !strings.Contains(correction, "blocked") {
		t.Fatalf("the correction does not name the ways out: %q", correction)
	}

	// The result's own goal operations count: closing the goal in the same
	// answer is closing it.
	closing := []ResultOperation{{
		ID: "goal-traffic-done", Type: "update_goal",
		GoalState: &GoalStateOperation{GoalID: "goal-traffic", State: core.GoalCompleted},
	}}
	if got := OpenRequiredGoalCorrection(goals, closing, done); got != "" {
		t.Fatalf("a completion that closes the goal it leaves open was still corrected: %q", got)
	}
	excluding := []ResultOperation{{
		ID: "goal-traffic-gone", Type: "update_goal",
		GoalState: &GoalStateOperation{GoalID: "goal-traffic", State: core.GoalExcluded, Detail: "false reading"},
	}}
	if got := OpenRequiredGoalCorrection(goals, excluding, done); got != "" {
		t.Fatalf("a completion that excludes the goal was still corrected: %q", got)
	}

	// A goal planned in the same result is open the moment the plan lands:
	// the wedged episode's first turn planned goal-traffic and completed in
	// one answer, and the kernel could only refuse it after the fact.
	planning := []ResultOperation{{
		ID: "plan-traffic", Type: "plan_goal",
		Goal: &GoalOperation{ID: "goal-fresh", Required: true, RequestedOutcome: "Sample the interface counters"},
	}}
	if got := OpenRequiredGoalCorrection(nil, planning, done); !strings.Contains(got, "goal-fresh") {
		t.Fatalf("a required goal planned by the completing result was not reported open: %q", got)
	}

	// A blocked completion is allowed to leave goals open; that is what
	// blocked means.
	blocked := &CompletionAssessment{Status: "blocked", Summary: "cannot reach the switch"}
	if got := OpenRequiredGoalCorrection(goals, nil, blocked); got != "" {
		t.Fatalf("a blocked completion was corrected for open goals: %q", got)
	}
	if got := OpenRequiredGoalCorrection(goals, nil, nil); got != "" {
		t.Fatalf("a result with no completion was corrected for open goals: %q", got)
	}
}
