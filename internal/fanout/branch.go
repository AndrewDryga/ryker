package fanout

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// BranchAttemptLimit is a branch's own correction budget, deliberately smaller
// than the episode's twenty.
//
// Sharing the episode budget would let one branch arguing with the host spend
// the allowance the other branches and the synthesis still need — and the
// branch spending it is by construction the one that understands its cluster
// least. Three corrections is enough for a read-only check to be told twice
// what shape its evidence must take.
const BranchAttemptLimit = 3

// BranchMarker separates the episode's conversation from the goal a branch is
// running. It is a marker rather than a separate column because the key has to
// change anyway — see BranchConversationKey — and a binding that falls out of
// the fix is one that cannot drift away from it.
//
// Exported because the fourth serializer is defeated in SQL. The agent-run
// lease has to tell a branch from a lead before any Go code sees the row, and
// the only thing on agent_runs that says so is this substring of the
// conversation key — there is no kind column. A second copy of "#branch:"
// written into that query would be a second definition of what a branch is,
// living in the one place nobody greps.
const BranchMarker = "#branch:"

// BranchConversationKey mints the conversation a branch runs under.
//
// This is the load-bearing detail of the whole feature. Two layers serialize on
// this key and neither is obvious from the code that queues work: the scheduled
// work lane will not lease an item whose conversation key already has a live
// lease, and the agent-run lease refuses any run whose conversation key is
// already preparing, running, applying or finalizing. A branch that inherited
// the episode's key would therefore be queued in parallel, reported as
// parallel, and executed one after another — the failure mode that looks
// exactly like success, and the reason this function exists rather than the
// caller appending a suffix at each of the two sites.
//
// A base that is already a branch key is normalized back to the lead's, so a
// branch cannot be minted from a branch and produce a key that parses to the
// wrong goal.
func BranchConversationKey(base, goalID string) string {
	if index := strings.Index(base, BranchMarker); index >= 0 {
		base = base[:index]
	}
	return base + BranchMarker + goalID
}

// IsBranch reports whether a conversation belongs to a branch rather than the
// lead. The lead's own key is never a branch, which is what keeps
// complete_episode reachable for exactly one attempt.
func IsBranch(conversationKey string) bool {
	_, ok := GoalOf(conversationKey)
	return ok
}

// GoalOf reads the goal a branch conversation was minted for.
//
// It takes the first marker, not the last, so a goal id that itself contains
// the marker round-trips: the outermost separator is the one the host wrote.
func GoalOf(conversationKey string) (string, bool) {
	index := strings.Index(conversationKey, BranchMarker)
	if index < 0 {
		return "", false
	}
	goalID := conversationKey[index+len(BranchMarker):]
	if strings.TrimSpace(goalID) == "" {
		return "", false
	}
	return goalID, true
}

// branchOperations is everything a branch may write, and the list is short on
// purpose: a branch exists to put what it learned into the one shared ledger
// the lead will read.
//
// Everything absent is absent for a stated reason. complete_episode because
// only the lead synthesizes. The offers, the approval and the visual because
// the episode's destination belongs to the lead, and three branches each
// offering the operator a button is the room noise the failure-visibility rules
// already forbid, arriving through a new door. plan_goal because a branch
// planning branches is how a bounded fan-out stops being bounded.
var branchOperations = map[string]bool{
	"record_evidence": true,
	"record_coverage": true,
	"update_goal":     true,
	"report_progress": true,
}

// BranchMayApply reports whether a branch's result operation is accepted into
// the shared ledger.
func BranchMayApply(operation string) bool {
	return branchOperations[strings.ToLower(strings.TrimSpace(operation))]
}

// BranchCompletionRefusal is the correction sent back when a branch decides the
// episode is finished.
//
// It is a rejection of the artifact, not of the answer, and the distinction is
// the whole point: the branch was given one cluster and it may well have
// settled it correctly. Discarding the turn would throw away the evidence the
// synthesis is waiting for, so what the branch found is kept and only the
// conclusion drawn from a third of the incident is refused.
func BranchCompletionRefusal(goalID string) string {
	return "This attempt is investigating goal " + goalID +
		", one independent part of a larger incident, and cannot complete the episode: " +
		"it has seen the evidence for its own goal and not the evidence for the others. " +
		"Record what you established with record_evidence and record_coverage, mark the " +
		"goal with update_goal, and the lead attempt will merge every branch's findings " +
		"and decide."
}

// BranchOutcome is what a branch's terminal state does to the episode around
// it.
type BranchOutcome struct {
	GoalID             string
	State              core.EpisodeGoalState
	Blocker            string
	EndsEpisode        bool
	NeedsPublicFailure bool
}

// BranchFailure turns a failed branch into the only thing it is allowed to be:
// a blocker on that branch's own goal.
//
// Not an episode failure, because the incident is not over — the other branches
// are still running and the lead has not synthesized. And not a room post,
// because one public failure per blocker generation still holds; a fan-out that
// fails two of three branches would otherwise report the same incident twice to
// the same channel, which is the behaviour the visibility gate was written to
// stop and which fan-out would multiply by three.
func BranchFailure(goalID, detail string) BranchOutcome {
	return BranchOutcome{
		GoalID:      goalID,
		State:       core.GoalBlocked,
		Blocker:     strings.TrimSpace(detail),
		EndsEpisode: false,
		// The lead reports what happened, once, having read the ledger the
		// blocked branch still contributed to.
		NeedsPublicFailure: false,
	}
}

// SynthesisReady reports whether every branch has stopped, which is when the
// lead may be queued to merge them.
//
// Stopped, not succeeded. Waiting for success would hang the episode on the
// first branch that blocked — and a blocked branch is information the synthesis
// wants, because "this could not be established" is half of most operational
// answers. A goal with no state recorded at all has not run yet and is not a
// stopped branch; treating an absent key as terminal would queue the synthesis
// against a ledger still being written.
func SynthesisReady(states map[string]core.EpisodeGoalState, branchGoalIDs []string) bool {
	for _, goalID := range branchGoalIDs {
		state, recorded := states[goalID]
		if !recorded || !terminalGoalState(state) {
			return false
		}
	}
	return len(branchGoalIDs) > 0
}

// terminalGoalState mirrors the set the store already treats as terminal when
// it stamps a goal's completed_at. Two lists that disagree would let the
// synthesis fire against a goal the store still considers open.
func terminalGoalState(state core.EpisodeGoalState) bool {
	switch state {
	case core.GoalCompleted, core.GoalBlocked, core.GoalExcluded, core.GoalCancelled:
		return true
	default:
		return false
	}
}
