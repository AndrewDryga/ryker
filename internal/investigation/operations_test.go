package investigation

import (
	"encoding/json"
	"strings"
	"testing"
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
		strings.Contains(string(encoded), "evidence_refs") {
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
