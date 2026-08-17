package decision

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// Found in the 2026-08-16 audit: the host knew exactly which field failed and
// told nobody. Two of these branches refused an answer without naming anything
// they had looked at — "the active issue has no actionable cause boundary" and
// "the active issue has no fresh verification plan for its mitigation" — so the
// model was told a shape was wrong without being told which field carried it.
// The cause-evidence correction beside them had already been given the opposite
// treatment on the same day, and reads back the exact ids it rejected.
//
// The verdict and cause_status are what the model must reconcile against, so a
// correction that omits them is asking for a rewrite of something the model
// believes it already supplied.
func TestTheDiagnosisCorrectionNamesWhatIsMissing(t *testing.T) {
	episode := core.WorkEpisode{Effort: core.EffortOperationalAssessment}
	coverage := []core.Coverage{{
		Layer: "application", Status: "degraded",
		Detail: "checkout latency is above its objective",
	}}
	completion := &investigation.CompletionAssessment{
		Status: "decision_ready", Summary: "Checkout is degraded but serving.",
	}
	evidence := []core.Evidence{{
		ID: "checkout-pool", ClaimID: "application.saturation",
		Relation: "supports", Claim: "the checkout pool is saturated",
		Observation: "the connection pool has been at its limit for twenty minutes",
	}}

	// A bounded cause with the cause sentence itself empty.
	noBoundary := &AlertAssessment{
		Verdict: "confirmed_issue", CauseStatus: "bounded",
		Impact:          "Checkout requests are slow for every customer.",
		ImmediateAction: "Raise the pool ceiling for the checkout service.",
		Verification:    "Watch checkout p99 return under its objective for ten minutes.",
	}
	got := EpisodeDiagnosisCorrection(
		episode, "reply", evidence, coverage, noBoundary, completion,
	)
	for _, want := range []string{"confirmed_issue", "bounded", "cause"} {
		if !strings.Contains(got, want) {
			t.Fatalf("the empty-cause correction never named %q: %q", want, got)
		}
	}

	// The same assessment with a cause and no verification plan.
	noVerification := *noBoundary
	noVerification.Cause = "the checkout pool ceiling is below the new traffic floor"
	noVerification.CauseClaimIDs = []string{"application.saturation"}
	noVerification.EvidenceRefs = []string{"checkout-pool"}
	noVerification.Verification = ""
	got = EpisodeDiagnosisCorrection(
		episode, "reply", evidence, coverage, &noVerification, completion,
	)
	for _, want := range []string{"verification", "confirmed_issue", "Raise the pool ceiling"} {
		if !strings.Contains(got, want) {
			t.Fatalf("the empty-verification correction never named %q: %q", want, got)
		}
	}

	// And the complete assessment is still accepted, so neither message becomes
	// a correction the model cannot clear.
	whole := noVerification
	whole.Verification = "Watch checkout p99 return under its objective for ten minutes."
	if got := EpisodeDiagnosisCorrection(
		episode, "reply", evidence, coverage, &whole, completion,
	); got != "" {
		t.Fatalf("a complete diagnosis was corrected anyway: %q", got)
	}
}
