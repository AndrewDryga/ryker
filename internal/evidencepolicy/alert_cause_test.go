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
	if got := AlertCauseCorrection(assessment, unrelated); !strings.Contains(got, "unrelated") {
		t.Fatalf("unrelated evidence correction = %q", got)
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
