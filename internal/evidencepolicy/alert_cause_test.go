package evidencepolicy

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

func TestAlertCauseCorrectionRequiresExplicitClaimBinding(t *testing.T) {
	assessment := &investigation.AlertAssessment{
		Verdict: "confirmed_issue", Cause: "A dependency is failing.",
		CauseClaimIDs: []string{"dependency.current_health"},
		EvidenceRefs:  []string{"dependency-failure"},
	}
	unrelated := []core.Evidence{{
		ID: "dependency-failure", ClaimID: "change.recent",
		Observation: "the deployment revision is current",
	}}
	// This asserted only that the word "unrelated" appeared, which is the word
	// the model could not act on: it named neither the reference nor the claim
	// that made it unrelated. The rule is unchanged; the demand is now that the
	// text identifies the record.
	got := AlertCauseCorrection(assessment, unrelated)
	for _, want := range []string{
		"dependency-failure", "change.recent", "dependency.current_health",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("unrelated evidence correction never named %q: %q", want, got)
		}
	}
	matching := []core.Evidence{{
		ID: "dependency-failure", ClaimID: "dependency.current_health",
		Claim: "the dependency is healthy", Observation: "the live probe failed",
		Relation: "contradicts",
	}}
	if got := AlertCauseCorrection(assessment, matching); got != "" {
		t.Fatalf("explicitly bound evidence rejected = %q", got)
	}
}
