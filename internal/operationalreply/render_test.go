package operationalreply

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/operationalscope"
)

// The reply that prompted this: a healthy-CDN assessment whose two cited
// observations were written as transcript, not prose. The renderer joined them
// with a space, so the operator-facing verdict — "no operational action" —
// arrived after a hundred words of curl timings, etags, pull-zone ids, and
// per-path abort counts. An on-call deciding whether to restart production
// reads the first line and stops there, and the first line was DNS latency.
func valorantAssessment() (*operationalscope.Assessment, []core.Evidence) {
	assessment := &operationalscope.Assessment{
		Verdict:         "not_issue",
		Impact:          "No user-facing impact; the CDN served every request",
		ImmediateAction: "No operational action; the fix belongs in the client",
		EvidenceRefs:    []string{"e-cdn"},
		Scope: &operationalscope.Scope{
			Status:            "bounded",
			CheckedTargets:    []string{"fe-utils static data"},
			UnverifiedTargets: []string{"Better Stack event breakdown"},
			EvidenceRefs:      []string{"e-aborts"},
		},
	}
	evidence := []core.Evidence{
		{
			ID: "e-cdn", ClaimID: "impact.current",
			Claim:       "The CDN served the static payload",
			Observation: "GET returned http_code=200 in 25.5 ms, etag W/2360cc, cdn-cache HIT",
			Relation:    "supports", HealthEffect: "none", Target: "fe-utils static data",
		},
		{
			ID: "e-aborts", ClaimID: "application.functional_behavior",
			Claim:       "Clients aborted fetches",
			Observation: "488 of 503 log rows are client aborts, evenly spread across all seven endpoints",
			Relation:    "supports", HealthEffect: "degraded", Target: "blitz-flutter client",
		},
	}
	return assessment, evidence
}

// The counterpart to the layout fix: leading with assessment.Impact was tried
// and reverted, because that field is arbitrary model prose that
// TestBoundedOperationalScopeMakesExclusiveParaphrasesIrrelevant already proved
// will over-claim past a bounded scope. Bulleting must not smuggle it back in.
func TestOperationalReplyNeverSurfacesModelImpactProse(t *testing.T) {
	assessment, evidence := valorantAssessment()
	assessment.Impact = "Every other endpoint on the pull zone is healthy"

	message, ok := Render(assessment, evidence)
	if !ok {
		t.Fatal("Render refused a complete assessment")
	}

	if strings.Contains(message, assessment.Impact) {
		t.Errorf("host surfaced unvalidated impact prose %q in:\n%s", assessment.Impact, message)
	}
}

func TestOperationalReplyGivesEachObservationItsOwnLine(t *testing.T) {
	assessment, evidence := valorantAssessment()

	message, ok := Render(assessment, evidence)
	if !ok {
		t.Fatal("Render refused a complete assessment")
	}

	for _, line := range strings.Split(message, "\n") {
		if strings.Count(line, "•") > 1 {
			t.Errorf("two observations share one line: %q", line)
		}
	}
	if bullets := strings.Count(message, "• "); bullets != 2 {
		t.Errorf("got %d bulleted observations, want 2 in:\n%s", bullets, message)
	}
	if strings.Contains(message, "cdn-cache HIT 488 of") {
		t.Error("observations were concatenated into one paragraph")
	}
}
