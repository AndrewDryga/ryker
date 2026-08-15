package investigation

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// OpenRequiredGoalCorrection reports a completion that would leave a required
// goal open, in words the model can act on.
//
// The kernel refuses to complete an episode while a required goal is planned,
// working, waiting, or blocked — the right invariant, enforced at the wrong
// moment for the model. It fired at finalization, after the result had been
// accepted, as a store error nobody relayed: run_dab83e5b completed the VA1
// bond0 investigation with a sound answer at 03:13Z on 2026-08-15 and then
// retried finalization every five minutes for three hours, forty attempts,
// against a required goal (goal-traffic, "Verify actual VA1 network and storage
// load") a turn had planned at 23:11Z and nothing had closed. The model was
// never told; there was nothing it could have said. Asked here, while the
// result is being staged, the same invariant becomes a correction with the
// three ways out named.
//
// The goal operations in the result are applied first, both ways: a completion
// that closes the goal it leaves open is not open, and a completion that plans
// a required goal in the same breath has opened one — the wedged run's first
// turn did exactly that, and the kernel saw it only once the plan was written.
func OpenRequiredGoalCorrection(
	goals []core.EpisodeGoal,
	operations []ResultOperation,
	completion *CompletionAssessment,
) string {
	if completion == nil || completion.Status == "blocked" {
		return ""
	}
	closedByResult := map[string]bool{}
	plannedByResult := make([]core.EpisodeGoal, 0)
	for _, operation := range operations {
		switch {
		case operation.Type == "update_goal" && operation.GoalState != nil:
			switch operation.GoalState.State {
			case core.GoalCompleted, core.GoalExcluded, core.GoalCancelled:
				closedByResult[strings.TrimSpace(operation.GoalState.GoalID)] = true
			}
		case operation.Type == "plan_goal" && operation.Goal != nil && operation.Goal.Required:
			plannedByResult = append(plannedByResult, core.EpisodeGoal{
				ID: strings.TrimSpace(operation.Goal.ID), Required: true,
				State: core.GoalPlanned, RequestedOutcome: operation.Goal.RequestedOutcome,
			})
		}
	}
	seen := map[string]bool{}
	open := make([]string, 0)
	for _, goal := range append(append([]core.EpisodeGoal{}, goals...), plannedByResult...) {
		if !goal.Required || closedByResult[goal.ID] || seen[goal.ID] {
			continue
		}
		seen[goal.ID] = true
		switch goal.State {
		case core.GoalCompleted, core.GoalExcluded, core.GoalCancelled:
			continue
		}
		open = append(open, goal.ID+" ("+strings.TrimSpace(goal.RequestedOutcome)+", "+string(goal.State)+")")
	}
	if len(open) == 0 {
		return ""
	}
	return "the completion leaves required goal(s) open: " + strings.Join(open, "; ") +
		". Before completing the episode, emit update_goal for each with state completed " +
		"(citing the evidence that satisfied it), excluded (with the reason it no longer applies), " +
		"or cancelled; if it cannot be closed, return completion.status blocked naming it as the blocker."
}
