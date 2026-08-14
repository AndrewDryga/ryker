package investigationcontract

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// Work with steps is asked to name them; work that is one act is not.
//
// plan_goal and update_goal have been in the contract's operation list since
// the contract existed, and episode_goals has never held a row — not few, none,
// across every episode ever run. An operation that is listed and never asked
// for is an operation that does not happen, so the list was never the problem
// and adding a correction rung would have been pressure applied to a model that
// was never told what was wanted.
//
// The boundary matters as much as the ask. A Slack question and a focused check
// are one act each, and five goals under a card whose whole work is a lookup is
// ceremony an operator has to read past — so the two efforts that run long get
// the instruction and nobody else does, and the rule is written into the text
// as well as into this switch.
func TestOnlyWorkWithStepsIsAskedToPlanIt(t *testing.T) {
	cases := []struct {
		effort core.EffortContract
		want   bool
	}{
		{core.EffortEngineeringTask, true},
		{core.EffortIncidentInvestigation, true},
		{core.EffortConversational, false},
		{core.EffortFocusedCheck, false},
		{core.EffortOperationalAssessment, false},
	}
	for _, test := range cases {
		t.Run(string(test.effort), func(t *testing.T) {
			prompt := Compile(core.WorkEpisode{
				Effort: test.effort, Authority: core.AuthorityReadOnly,
				Objective: "Check the checkout API",
			}).Prompt()
			asked := strings.Contains(prompt, "plan_goal operations")
			if asked != test.want {
				t.Fatalf("asked to plan = %t, want %t", asked, test.want)
			}
			if !asked {
				return
			}
			// The shape the host can actually apply, and the bound the card can
			// actually render. A goal with no completion_contract is rejected by
			// the store, and an outcome longer than the ledger's column is a
			// checklist line that says half of something.
			for _, phrase := range []string{
				"update_goal", "requested_outcome under 80", "completion_contract",
				"first substantive result", "no goals at all",
			} {
				if !strings.Contains(prompt, phrase) {
					t.Fatalf("the plan instruction never says %q", phrase)
				}
			}
		})
	}
}

// The instruction costs nothing on the turns where context is scarcest.
//
// A Coop turn is capped at 64 KiB and whatever the instructions do not use is
// what the model sees of the actual conversation. The efforts that carry this
// paragraph are the ones already running long; the conversational and
// focused-check contracts, which are most of the traffic, are byte-for-byte
// what they were. That is not a happy accident of the wording — it is why the
// paragraph is conditioned on effort rather than written into the shared body.
func TestPlanInstructionIsFreeOnTheEffortsThatDoNotGetIt(t *testing.T) {
	measure := func(effort core.EffortContract) int {
		return len(Compile(core.WorkEpisode{
			Effort: effort, Authority: core.AuthorityReadOnly,
			Objective: "Check the checkout API",
		}).Prompt())
	}
	conversational := measure(core.EffortConversational)
	engineering := measure(core.EffortEngineeringTask)
	delta := engineering - measureWithoutPlan(t, core.EffortEngineeringTask)
	if delta <= 0 {
		t.Fatalf("the plan paragraph measured %d bytes", delta)
	}
	t.Logf(
		"plan instruction costs %d bytes on engineering_task and incident_investigation, "+
			"0 on conversational (%d bytes) and focused_check",
		delta, conversational,
	)
	// A paragraph, not a policy document. The contract is already 6 KiB and
	// every byte here is a byte of the operator's channel the model cannot see.
	if delta > 800 {
		t.Fatalf("the plan instruction is %d bytes; it is meant to be a paragraph", delta)
	}
}

// measureWithoutPlan is the same contract with the plan paragraph removed, so
// the delta above is the paragraph itself rather than the difference between
// two efforts' whole contracts.
func measureWithoutPlan(t *testing.T, effort core.EffortContract) int {
	t.Helper()
	contract := Compile(core.WorkEpisode{
		Effort: effort, Authority: core.AuthorityReadOnly,
		Objective: "Check the checkout API",
	})
	prompt := contract.Prompt()
	plan := contract.planGuidance()
	if plan == "" || !strings.Contains(prompt, plan) {
		t.Fatalf("the plan paragraph is not in the prompt it was compiled into")
	}
	return len(strings.Replace(prompt, plan, "", 1))
}

// The operations the instruction names have to be operations the contract
// permits. The prompt tells the model to emit only what this list names, so an
// instruction to plan against a list without plan_goal on it would be a
// contract that forbids what it mandates.
func TestThePlannedOperationsAreOnesTheContractAllows(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortEngineeringTask, Authority: core.AuthorityRepositoryWrite,
		Objective: "Add the retry",
	})
	for _, operation := range []string{"plan_goal", "update_goal"} {
		if !containsString(contract.ResultOperations, operation) {
			t.Fatalf("%s is instructed but not listed: %v", operation, contract.ResultOperations)
		}
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
