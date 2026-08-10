package investigation

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// The exact strings six real regression turns emitted, against the contract
// that compiled for them. Each one lost a complete, correct investigation.
func TestResolveClaimIDBindsTheOnlyClaimItsNamespaceCanName(t *testing.T) {
	task := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"task"},
		Objective: "Create reusable deep infrastructure health review runbook",
	})
	platform := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment,
		RequiredCoverage: []string{
			"change", "host", "runtime", "workload", "dependency", "application", "slo",
		},
		Objective: "Assess whole-platform health",
	})
	for _, item := range []struct {
		contract InvestigationContract
		spelling string
		want     string
	}{
		{task, "task.requested_outcome", "task.requested_outcome"},
		{task, "task.completion", "task.requested_outcome"},
		{task, "task.current_state", "task.requested_outcome"},
		{task, "task", "task.requested_outcome"},
		{task, "  Task.Completion  ", "task.requested_outcome"},
		{platform, "application.errors", "application.functional_behavior"},
		// The slo layer's claim is spelled impact.current, so both the layer
		// name and the claim's own namespace have to reach it.
		{platform, "slo", "impact.current"},
		{platform, "slo.current", "impact.current"},
		{platform, "impact.observed", "impact.current"},
	} {
		got, ok := item.contract.ResolveClaimID(item.spelling)
		if !ok || got != item.want {
			t.Errorf("ResolveClaimID(%q) = %q, %t; want %q", item.spelling, got, ok, item.want)
		}
	}
}

// The guarantee is that the contract leaves no room for doubt, not that a
// near-miss is forgiven. A namespace the contract does not require, and a
// namespace two required claims share, both stay rejected.
func TestResolveClaimIDRefusesAnythingItCannotPinToOneClaim(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"task"},
		Objective: "Create reusable deep infrastructure health review runbook",
	})
	for _, spelling := range []string{"", "   ", "application.functional_behavior", "impact", "outcome"} {
		if got, ok := contract.ResolveClaimID(spelling); ok {
			t.Errorf("ResolveClaimID(%q) resolved to %q; want a refusal", spelling, got)
		}
	}

	shared := InvestigationContract{Claims: []ClaimRequirement{
		{ID: "task.plan", Layer: "task", Required: true},
		{ID: "task.result", Layer: "delivery", Required: true},
	}}
	if got, ok := shared.ResolveClaimID("task.progress"); ok {
		t.Errorf("an ambiguous namespace resolved to %q; want a refusal", got)
	}
	// An exact id still wins outright when its namespace is shared.
	if got, ok := shared.ResolveClaimID("task.result"); !ok || got != "task.result" {
		t.Errorf("exact id resolved to %q, %t", got, ok)
	}
	// An optional claim is not a required one, so it never captures a namespace.
	optional := InvestigationContract{Claims: []ClaimRequirement{
		{ID: "task.plan", Layer: "task", Required: false},
	}}
	if got, ok := optional.ResolveClaimID("task"); ok {
		t.Errorf("an optional claim captured the namespace as %q", got)
	}
}

// The whole path, on the exact shape a real turn produced: the right source,
// the right observation, the right coverage layer, and one invented word after
// the dot. It used to be discarded; the layer has exactly one required claim,
// so there was never a second question it could have been answering.
func TestClaimCorrectionAcceptsTheOneSpellingTheLayerCanMean(t *testing.T) {
	now := time.Date(2026, 8, 10, 2, 37, 19, 0, time.UTC)
	episode := core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"task"},
		Objective: "Create reusable deep infrastructure health review runbook",
	}
	evidence := []core.Evidence{{
		ClaimID: "task.current_state", Relation: "supports", HealthEffect: "none",
		Claim:       "Current state of the requested reusable runbook",
		Observation: "Emisar listed deep-infrastructure-health-review@2 as an available draft.",
		SourceType:  "emisar", SourceName: "Emisar list_runbooks", ObservedAt: now,
		Confidence: "high",
		Dimensions: map[string]string{
			"artifact": "deep-infrastructure-health-review", "revision": "@2",
		},
	}}
	coverage := []core.Coverage{{
		Layer: "task", ClaimIDs: []string{"task.current_state"}, Status: "healthy",
		Detail:     "The requested reusable runbook exists as an available draft.",
		ObservedAt: now,
	}}
	completion := &CompletionAssessment{
		Status: "decision_ready", Summary: "The runbook exists as a validated draft.",
	}
	if got := ClaimCorrection(
		episode, "reply", evidence, coverage, completion, now, true,
	); got != "" {
		t.Fatalf("an unambiguous claim spelling was rejected: %q", got)
	}
}

// Rejection still happens, and now it hands over the strings the host is
// waiting for. Repeating "an exact required claim_id" three corrections
// running never once produced the string.
func TestClaimCorrectionNamesTheClaimIDsItWants(t *testing.T) {
	now := time.Date(2026, 8, 10, 2, 37, 19, 0, time.UTC)
	episode := core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, Objective: "Assess whole-platform health",
		RequiredCoverage: []string{"application", "slo"},
	}
	completion := &CompletionAssessment{
		Status: "decision_ready", Verdict: "degraded", Summary: "Rivals is degraded.",
	}
	got := ClaimCorrection(episode, "reply", nil, []core.Coverage{
		{Layer: "application", Status: "degraded", Detail: "Rivals endpoints fail."},
		{Layer: "slo", Status: "degraded", Detail: "No formal SLO exists."},
	}, completion, now, true)
	if !strings.Contains(got, "no typed evidence") {
		t.Fatalf("a completion with no evidence was accepted: %q", got)
	}
	for _, want := range []string{"application.functional_behavior", "impact.current"} {
		if !strings.Contains(got, want) {
			t.Errorf("correction %q does not name %q", got, want)
		}
	}
}

// The ledger reads the same resolution, so a claim answered under a spelling
// the contract can only read one way counts as answered rather than as an
// unknown claim with unrelated stale evidence beside it.
func TestLedgerBindsEvidenceThroughTheResolvedClaimID(t *testing.T) {
	now := time.Date(2026, 8, 9, 23, 53, 44, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"task"},
		Objective: "Create reusable deep infrastructure health review runbook",
	})
	ledger := BuildLedger(contract, []core.Evidence{{
		ClaimID: "task.completion", Relation: "supports", HealthEffect: "none",
		SourceType: "emisar", SourceName: "Emisar update_runbook_draft",
		Observation: "Emisar saved a validated 12-check draft.",
		ObservedAt:  now, Confidence: "high",
		Dimensions: map[string]string{
			"artifact": "deep-infrastructure-health-review", "revision": "@2",
		},
	}}, []core.Coverage{{
		Layer: "task", ClaimIDs: []string{"task.completion"}, Status: "healthy",
		Detail: "The requested reusable runbook exists as a validated draft.",
	}}, now)
	view := ledger.Claims["task.requested_outcome"]
	if view.State != ClaimSupported || len(view.Evidence) != 1 {
		t.Fatalf("claim view = %+v", view)
	}
	if correction := ledger.CompletionCorrectionFor("decision_ready", "confirmed"); correction != "" {
		t.Fatalf("resolved evidence rejected: %q", correction)
	}
}

// The dimension gap names the object keys the evidence has to carry. It used
// to read as a remark about scope, and three corrections in a row answered it
// by rewording the observation instead of adding the keys.
func TestMissingDimensionsCorrectionNamesThemAsEvidenceKeys(t *testing.T) {
	now := time.Date(2026, 8, 9, 23, 53, 44, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"task"},
		Objective: "Create reusable deep infrastructure health review runbook",
	})
	ledger := BuildLedger(contract, []core.Evidence{{
		ClaimID: "task.requested_outcome", Relation: "supports", HealthEffect: "none",
		SourceType: "emisar", SourceName: "Emisar draft inspection",
		Observation: "Draft execution succeeded across all three stages.",
		ObservedAt:  now, Confidence: "high",
		Dimensions: map[string]string{"runbook": "deep-infrastructure-health-review@1"},
	}}, []core.Coverage{{
		Layer: "task", ClaimIDs: []string{"task.requested_outcome"}, Status: "healthy",
		Detail: "The exact runbook draft passed its complete test.",
	}}, now)
	correction := ledger.CompletionCorrectionFor("decision_ready", "confirmed")
	for _, want := range []string{"dimensions keys", "artifact", "revision"} {
		if !strings.Contains(correction, want) {
			t.Fatalf("dimension correction %q does not name %q", correction, want)
		}
	}
}
