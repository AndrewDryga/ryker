package evidencepolicy

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// A recovered alert could name a root cause with nothing tying it to anything
// observed, and say so in the channel, because the binding rule ran only for a
// confirmed or likely issue. A claim about why something broke needs the same
// support whether or not it is still broken.
// Covers: TestAlertCauseCorrectionRejectsUnboundCauseOnRecoveredAssessment
func TestRecoveredAlertMustStillBindTheCauseItNames(t *testing.T) {
	naming := &investigation.AlertAssessment{
		Verdict: "not_issue", Impact: "none",
		Cause: "a leak in the new revision", CauseStatus: "identified",
	}
	if correction := AlertCauseCorrection(naming, nil); correction == "" {
		t.Fatal("a recovered alert named a cause with nothing binding it")
	}

	// Recovered and saying only that it recovered is the ordinary case, and it
	// asserts nothing that needs binding.
	quiet := &investigation.AlertAssessment{Verdict: "not_issue", Impact: "none"}
	if correction := AlertCauseCorrection(quiet, nil); correction != "" {
		t.Fatalf("a recovery that named no cause was corrected: %q", correction)
	}
	// Neither does one that says plainly it could not establish the cause.
	unverified := &investigation.AlertAssessment{
		Verdict: "not_issue", Impact: "none",
		Cause: "possibly memory pressure", CauseStatus: "unverified",
	}
	if correction := AlertCauseCorrection(unverified, nil); correction != "" {
		t.Fatalf("an explicitly unverified cause was corrected: %q", correction)
	}

	// Bound properly, it passes.
	bound := &investigation.AlertAssessment{
		Verdict: "not_issue", Impact: "none",
		Cause: "a leak in the new revision", CauseStatus: "identified",
		CauseClaimIDs: []string{"host.current_state"}, EvidenceRefs: []string{"evidence-host"},
	}
	if correction := AlertCauseCorrection(bound, []core.Evidence{{
		ID: "evidence-host", ClaimID: "host.current_state",
		Observation: "Memory climbed with the new revision and fell after rollback.",
	}}); correction != "" {
		t.Fatalf("a properly bound cause was corrected: %q", correction)
	}
}
