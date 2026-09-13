package fanout

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
)

// The queue serializes on the conversation key: neither the scheduled work lane
// nor the agent-run lease will start an item while another with the same key is
// running. Branches that inherited the episode's key would therefore run one
// after another while every counter said "parallel" — the failure that looks
// exactly like success. The key has to differ, and carrying the goal in it is
// what also makes a branch run identifiable later without a new column.
func TestABranchGetsItsOwnConversationSoTheQueueDoesNotSerializeIt(t *testing.T) {
	base := "incident:inc_123"
	first := BranchConversationKey(base, "goal-host")
	second := BranchConversationKey(base, "goal-dependency")
	if first == base || second == base {
		t.Fatalf("a branch kept the episode's conversation key: %q, %q", first, second)
	}
	if first == second {
		t.Fatalf("two branches share the conversation key %q and will serialize", first)
	}
}

func TestABranchRunIsIdentifiableByItsConversationAlone(t *testing.T) {
	key := BranchConversationKey("incident:inc_123", "goal-host")
	if !IsBranch(key) {
		t.Fatalf("%q was not recognised as a branch", key)
	}
	goal, ok := GoalOf(key)
	if !ok || goal != "goal-host" {
		t.Fatalf("GoalOf(%q) = %q, %t; want the goal it was minted for", key, goal, ok)
	}
	for _, lead := range []string{"incident:inc_123", "channel:C123", "operation:C1:key", ""} {
		if IsBranch(lead) {
			t.Fatalf("the lead's conversation %q was read as a branch", lead)
		}
		if goal, ok := GoalOf(lead); ok {
			t.Fatalf("GoalOf(%q) invented the goal %q", lead, goal)
		}
	}
}

// A goal id containing the marker must not let a branch impersonate another
// goal, and must not silently produce a key that parses back to something else.
func TestABranchKeyRoundTripsWhateverTheGoalIsCalled(t *testing.T) {
	for _, goalID := range []string{
		"goal-host", "goal.with.dots", "goal#branch:other", "goal with spaces",
	} {
		key := BranchConversationKey("incident:inc_123", goalID)
		got, ok := GoalOf(key)
		if !ok {
			t.Fatalf("a key minted for %q does not read back as a branch: %q", goalID, key)
		}
		if got != goalID {
			t.Fatalf("GoalOf(%q) = %q, want %q", key, got, goalID)
		}
	}
}

// Only the lead synthesizes. A branch that decides the episode is finished has
// answered a question nobody asked it — it saw one cluster, not the incident —
// and accepting it would publish a conclusion drawn from a third of the
// evidence. It is a correction against the artifact, not against the answer:
// what the branch found is still worth keeping.
func TestABranchMayNotCompleteTheEpisode(t *testing.T) {
	if BranchMayApply("complete_episode") {
		t.Fatalf("a branch was allowed to complete the episode")
	}
	refusal := BranchCompletionRefusal("goal-host")
	if strings.TrimSpace(refusal) == "" {
		t.Fatalf("a branch's completion was refused with no correction to send back")
	}
	if !strings.Contains(refusal, "goal-host") {
		t.Fatalf("the correction does not name the branch's goal: %q", refusal)
	}
}

// What a branch is for: everything it learns goes into the one shared ledger
// the lead will read, and nothing else.
func TestABranchWritesEvidenceIntoTheSharedLedger(t *testing.T) {
	for _, operation := range []string{
		"record_evidence", "record_coverage", "record_finding", "update_goal", "report_progress",
	} {
		if !BranchMayApply(operation) {
			t.Fatalf("a branch could not %s, which is the work it exists to do", operation)
		}
	}
}

// No offers, no approvals, no visuals, no memory: the episode's destination and
// everything posted to it belong to the lead. Three branches each offering the
// operator a button is the room noise the failure-visibility rules exist to
// prevent, arriving through a new door.
func TestABranchMakesNoOffersAndOwnsNoDestination(t *testing.T) {
	for _, operation := range []string{
		"offer_task", "offer_memory", "offer_preference", "offer_rule", "offer_schedule",
		"request_approval", "request_operator_input", "attach_visual", "update_memory",
		"plan_goal", "complete_episode",
	} {
		if BranchMayApply(operation) {
			t.Fatalf("a branch was allowed to %s", operation)
		}
	}
}

// A branch that fails has failed to answer one question. The incident is not
// over, the other branches are still running, and the room hears nothing — one
// public failure per blocker generation still holds.
func TestABranchFailureBlocksOnlyItsOwnGoal(t *testing.T) {
	outcome := BranchFailure("goal-host", "Emisar returned no snapshot for nomad-hvn03")
	if outcome.GoalID != "goal-host" {
		t.Fatalf("the failure landed on %q, not the branch's own goal", outcome.GoalID)
	}
	if outcome.State != core.GoalBlocked {
		t.Fatalf("a failed branch left its goal %q, want %q", outcome.State, core.GoalBlocked)
	}
	if outcome.EndsEpisode {
		t.Fatalf("one branch's failure ended the whole episode")
	}
	if outcome.NeedsPublicFailure {
		t.Fatalf("a branch failure was routed to the room")
	}
	if !strings.Contains(outcome.Blocker, "nomad-hvn03") {
		t.Fatalf("the blocker does not carry the detail: %q", outcome.Blocker)
	}
}

// The lead is queued when every branch has stopped, whichever way it stopped.
// Waiting only for success would hang the episode on the first blocked branch;
// not waiting at all would synthesize from a ledger still being written.
func TestSynthesisWaitsForEveryBranchToStop(t *testing.T) {
	branches := []string{"goal-host", "goal-dependency"}
	if SynthesisReady(map[string]core.EpisodeGoalState{
		"goal-host":       core.GoalCompleted,
		"goal-dependency": core.GoalWorking,
	}, branches) {
		t.Fatalf("synthesis was queued while a branch was still working")
	}
	for _, stopped := range []core.EpisodeGoalState{
		core.GoalCompleted, core.GoalBlocked, core.GoalExcluded, core.GoalCancelled,
	} {
		if !SynthesisReady(map[string]core.EpisodeGoalState{
			"goal-host": core.GoalCompleted, "goal-dependency": stopped,
		}, branches) {
			t.Fatalf("a branch that stopped as %q did not release synthesis", stopped)
		}
	}
	// A goal with no state recorded has not run yet; it is not a stopped branch.
	if SynthesisReady(map[string]core.EpisodeGoalState{"goal-host": core.GoalCompleted}, branches) {
		t.Fatalf("synthesis was queued with a branch that has no state at all")
	}
}

// A branch gets its own, smaller correction budget. Sharing the episode's
// twenty means one branch arguing with the host can spend the allowance the
// other branches and the synthesis still need.
func TestABranchCorrectionBudgetIsItsOwnAndSmaller(t *testing.T) {
	if BranchAttemptLimit >= 20 {
		t.Fatalf("a branch may spend %d attempts, which is the episode's whole budget",
			BranchAttemptLimit)
	}
	if BranchAttemptLimit < 1 {
		t.Fatalf("a branch may spend %d attempts and can never run", BranchAttemptLimit)
	}
}
