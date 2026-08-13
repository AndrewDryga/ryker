package investigation

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestAlertAssessmentAcceptsKnownSemanticAliases(t *testing.T) {
	var assessment AlertAssessment
	err := json.Unmarshal([]byte(`{
		"alert":"repair_overdue",
		"component":"cassandra",
		"state":"recovered",
		"verdict":"not_issue",
		"impact":"The repair completed.",
		"durable_solution":"Keep the schedule in place.",
		"evidence_refs":["repair-complete"]
	}`), &assessment)
	if err != nil {
		t.Fatal(err)
	}
	if assessment.LongTermSolution != "Keep the schedule in place." {
		t.Fatalf("long-term solution = %q", assessment.LongTermSolution)
	}
	encoded, err := json.Marshal(assessment)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "durable_solution") ||
		!strings.Contains(string(encoded), `"evidence_refs":["repair-complete"]`) {
		t.Fatalf("aliases leaked into canonical output: %s", encoded)
	}
}

func TestAlertAssessmentRejectsUnknownFields(t *testing.T) {
	var assessment AlertAssessment
	err := json.Unmarshal([]byte(`{
		"verdict":"not_issue",
		"impact":"Recovered.",
		"surprise":"not in the contract"
	}`), &assessment)
	if err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("unexpected error = %v", err)
	}
}

// A proposed action is refused by name, not dropped and not misdiagnosed.
//
// The host used to accept propose_action, hand the proposal to the service, and
// drop it there for want of a configured action — a log line and nothing an
// operator or the model would ever see. The operation is now out of the prompt
// and out of the code, and what remains is a refusal that says where the
// request belongs. It has to stay a refusal: deleting the payload field instead
// would make the strict decoder complain about a field name, which invites the
// model to guess at spelling rather than to stop proposing.
func TestProposeActionIsRefusedWithItsReason(t *testing.T) {
	var operation ResultOperation
	if err := json.Unmarshal([]byte(`{
		"id":"propose-1",
		"type":"propose_action",
		"proposal":{"action_name":"restart_allocation","target":"alloc-123"}
	}`), &operation); err != nil {
		t.Fatalf("a proposal must parse far enough to be refused by name: %v", err)
	}
	err := operation.Validate()
	if err == nil {
		t.Fatal("propose_action was accepted")
	}
	for _, want := range []string{"propose-1", "no longer carries", "request_approval"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("refusal does not say %q: %v", want, err)
		}
	}
	if strings.Contains(ResultOperationsPrompt(), "propose_action") {
		t.Fatal("the prompt still asks for an operation the host refuses")
	}
}

// A coverage entry whose status was not in the set used to be dropped in
// silence during sanitization, and the layer it assessed was then reported back
// as never assessed at all — so the model rechecked what it had just checked,
// with nothing in the record saying its answer had been thrown away for its
// spelling.
func TestCoverageOperationRejectsUnsupportedStatusWithTheAllowedSet(t *testing.T) {
	invalid := ResultOperation{
		ID: "coverage-app", Type: "record_coverage",
		Coverage: &core.Coverage{
			Layer: "application", Status: "verified", Detail: "checked the endpoints",
		},
	}
	err := invalid.Validate()
	if err == nil {
		t.Fatal("an unsupported coverage status was accepted")
	}
	for _, want := range []string{"verified", "application", "healthy", "not_applicable"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("rejection %q does not name %q", err, want)
		}
	}

	// "covered" is the one alias the host understands, and it still normalizes
	// rather than being rejected.
	alias := invalid
	alias.Coverage = &core.Coverage{Layer: "application", Status: "covered"}
	if err := alias.Validate(); err != nil {
		t.Fatalf("the covered alias was rejected: %v", err)
	}
	valid := invalid
	valid.Coverage = &core.Coverage{Layer: "application", Status: "degraded"}
	if err := valid.Validate(); err != nil {
		t.Fatalf("a supported status was rejected: %v", err)
	}
}

// Every operation is a verb and a noun, and a model reaching for the noun alone
// wrote alert_assessment where record_alert_assessment was meant. The whole
// response was rejected for it — three times in the recorded history, on
// results that were otherwise complete.
func TestOperationNamedAfterItsPayloadResolves(t *testing.T) {
	operation := ResultOperation{
		ID: "alert-assessment", Type: "alert_assessment",
		AlertAssessment: &AlertAssessment{
			Verdict: "not_issue", Impact: "none",
		},
	}
	encoded, err := json.Marshal(operation)
	if err != nil {
		t.Fatal(err)
	}
	var decoded ResultOperation
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	// Normalized on the operation itself, because folding, suppression and
	// completion all switch on this string.
	if decoded.Type != "record_alert_assessment" {
		t.Fatalf("type = %q, want it resolved to the real operation", decoded.Type)
	}

	// An exact match always wins, so a real type can never be shadowed.
	if got := resolveOperationType("complete_episode"); got != "complete_episode" {
		t.Fatalf("an exact type was rewritten to %q", got)
	}
	// Nothing is invented: a name with no real operation behind it stays put
	// and is rejected as before.
	if got := resolveOperationType("teleport_pod"); got != "teleport_pod" {
		t.Fatalf("an unknown type became %q", got)
	}
}
