package investigation

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// The contract's own operation list is an allowlist as far as the model is
// concerned — the prompt says to emit only what it names — so it must not omit
// an operation the same prompt requires, or the only one that can reach a
// lifecycle state the host implements.
func TestStatedResultOperationsCoverWhatTheContractDemands(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, Objective: "Assess whole-platform health",
		RequiredCoverage: []string{"application", "slo"},
	})
	for _, required := range []string{
		// Mandated by the same instructions: one coverage item per required claim.
		"record_coverage",
		// The host's only way to ask a question. Its absence is what a model
		// answered by inventing completion.status "needs_input".
		"request_operator_input",
		"record_evidence",
		"complete_episode",
	} {
		if !slices.Contains(contract.ResultOperations, required) {
			t.Errorf("the contract forbids %q while the host requires or supports it", required)
		}
	}
	for _, stated := range contract.ResultOperations {
		if _, ok := resultOperationValidators[stated]; !ok {
			t.Errorf("the contract lists %q, which no result operation validator accepts", stated)
		}
	}
	if !strings.Contains(contract.Prompt(), `"request_operator_input"`) {
		t.Error("the serialized contract does not carry its own operation list")
	}
}

// A request for the operator to decide has exactly one legal shape, and the
// contract has to say which. Two real turns needed it: one invented
// completion.status "needs_input", the other emitted a two-field blocked
// completion. Both lost the response.
func TestContractStatesTheOperatorInputExit(t *testing.T) {
	prompt := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, Objective: "Assess whole-platform health",
		RequiredCoverage: []string{"application"},
	}).Prompt()
	for _, required := range []string{
		"completion.status is decision_ready or blocked and nothing else",
		"request_operator_input",
		"operator_input_required",
		"all five",
	} {
		if !strings.Contains(prompt, required) {
			t.Errorf("the contract prompt lacks %q", required)
		}
	}
	// The blocker kind it points at has to be one the validator accepts.
	if !validCompletionBlockerKind("operator_input_required") {
		t.Error("the contract points at a blocker kind the validator refuses")
	}
	// And the status it forbids has to stay forbidden.
	if err := ValidateCompletion(&CompletionAssessment{
		Status: "needs_input", Summary: "the request is truncated",
	}); err == nil {
		t.Error("needs_input was accepted as a completion status")
	}
}

// The claim dimensions are enforced by the ledger, so the contract has to say
// that they are keys of the evidence object rather than leaving the model to
// infer it from a JSON array beside an example that shows free-form keys.
func TestContractSaysWhereClaimDimensionsGo(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"task"},
		Objective: "Create reusable deep infrastructure health review runbook",
	})
	prompt := contract.Prompt()
	if !strings.Contains(prompt, "a key for every dimension that required claim lists") {
		t.Errorf("the contract prompt does not say where claim dimensions go:\n%s", prompt)
	}
	// The rule is only teachable because the contract ships the list.
	var wire struct {
		Claims []struct {
			ID         string   `json:"id"`
			Dimensions []string `json:"dimensions"`
		} `json:"required_claims"`
	}
	start := strings.Index(prompt, "{")
	end := strings.Index(prompt, "\nThis contract controls")
	if err := json.Unmarshal([]byte(prompt[start:end]), &wire); err != nil {
		t.Fatalf("the serialized contract is not valid JSON: %v", err)
	}
	if len(wire.Claims) != 1 || !slices.Equal(wire.Claims[0].Dimensions, []string{"artifact", "revision"}) {
		t.Fatalf("serialized claims = %+v", wire.Claims)
	}
}
