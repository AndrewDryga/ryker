package investigation

import (
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestCompileProducesOneOperationalContract(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, Authority: core.AuthorityReadOnly,
		Objective: "Assess production", RequiredCoverage: []string{"host", "application", "slo"},
		CompletionCriteria: []string{"return a decision"},
	})
	if contract.Version != Version || len(contract.Claims) != 3 ||
		contract.Completion.ConclusionKind != "operational_health" ||
		len(contract.Completion.AllowedVerdicts) != 3 || !contract.Completion.AllowUnknownSLO {
		t.Fatalf("contract = %+v", contract)
	}
	prompt := contract.Prompt()
	for _, required := range []string{
		"<host-investigation-contract>", "host.current_state", "completion.verdict",
		"record_evidence", "complete_episode",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("prompt lacks %q:\n%s", required, prompt)
		}
	}
}

func TestCompileUsesLifecycleVerdictsForFocusedChangeReview(t *testing.T) {
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Authority: core.AuthorityReadOnly,
		Objective: "Review this Terraform plan", RequiredCoverage: []string{"change", "host"},
	})
	if contract.Completion.ConclusionKind != "change_review" ||
		!slices.Contains(contract.Completion.AllowedVerdicts, "in_progress") ||
		slices.Contains(contract.Completion.AllowedVerdicts, "degraded") {
		t.Fatalf("change contract = %+v", contract.Completion)
	}
	if got := contract.Claims[0].Proposition; !strings.Contains(got, "lifecycle state") {
		t.Fatalf("change proposition = %q", got)
	}
	for _, required := range []string{"in_progress", "risk or unknown", "health_effect"} {
		if !strings.Contains(contract.Prompt(), required) {
			t.Fatalf("change contract prompt lacks %q", required)
		}
	}
}

func TestLedgerRejectsStaleIncompleteAndContradictoryClaims(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, Authority: core.AuthorityReadOnly,
		RequiredCoverage: []string{"host"},
	})
	claimID := contract.Claims[0].ID
	ledger := BuildLedger(contract, []core.Evidence{{
		ID: "old", ClaimID: claimID, Relation: "supports", Confidence: "high",
		ObservedAt: now.Add(-time.Hour), Dimensions: map[string]string{"host": "api-1"},
	}}, nil, now)
	if correction := ledger.CompletionCorrection("decision_ready"); !strings.Contains(correction, "stale") {
		t.Fatalf("stale correction = %q", correction)
	}

	ledger = BuildLedger(contract, []core.Evidence{
		{ID: "yes", ClaimID: claimID, Relation: "supports", Confidence: "high", ObservedAt: now,
			Dimensions: map[string]string{"host": "api-1", "environment": "production"}},
		{ID: "no", ClaimID: claimID, Relation: "contradicts", Confidence: "high", ObservedAt: now,
			Dimensions: map[string]string{"host": "api-2", "environment": "production"}},
	}, []core.Coverage{{
		Layer: "host", ClaimIDs: []string{"host.current_state"}, Status: "healthy",
		Detail: "The current host is responsive.",
	}}, now)
	if correction := ledger.CompletionCorrection("decision_ready"); !strings.Contains(correction, "contradictions") {
		t.Fatalf("contradiction correction = %q", correction)
	}
}

func TestLedgerDoesNotTurnRiskIntoOperationalDegradation(t *testing.T) {
	now := time.Date(2026, 8, 3, 14, 34, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, RequiredCoverage: []string{"host"},
	})
	claimID := contract.Claims[0].ID
	evidence := []core.Evidence{{
		ID: "busy-disks", ClaimID: claimID, Relation: "contradicts", HealthEffect: "risk",
		Observation: "Three storage devices were busy, while latency stayed low and no failure or impact was observed.",
		SourceType:  "emisar", SourceName: "host storage sample", ObservedAt: now,
		Dimensions: map[string]string{"host": "db-1", "environment": "production"},
	}}
	coverage := []core.Coverage{{
		Layer: "host", ClaimIDs: []string{claimID}, Status: "degraded",
		Detail: "Storage utilization is elevated without observed loss of capability.",
	}}
	ledger := BuildLedger(contract, evidence, coverage, now)
	if ledger.Claims[claimID].Resolved {
		t.Fatalf("risk-only evidence resolved degraded coverage: %+v", ledger.Claims[claimID])
	}
	if correction := ledger.CompletionCorrection("decision_ready"); !strings.Contains(correction, "unresolved contradictions") {
		t.Fatalf("risk-only correction = %q", correction)
	}

	evidence[0].HealthEffect = "degraded"
	evidence[0].Observation = "Storage latency exceeded the service bound and requests timed out."
	ledger = BuildLedger(contract, evidence, coverage, now)
	if correction := ledger.CompletionCorrection("decision_ready"); correction != "" {
		t.Fatalf("material degradation rejected: %q", correction)
	}
}

func TestLedgerAllowsDecisionReadyInProgressChange(t *testing.T) {
	now := time.Date(2026, 8, 3, 14, 34, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"change"},
	})
	claimID := contract.Claims[0].ID
	ledger := BuildLedger(contract, []core.Evidence{{
		ID: "run-state", ClaimID: claimID, Relation: "supports", HealthEffect: "risk",
		Observation: "The exact run is applying; its terminal result is not available yet.",
		SourceType:  "emisar", SourceName: "HCP Terraform", ObservedAt: now,
		Dimensions: map[string]string{"repository": "infra", "environment": "production", "revision": "0e279e6d"},
	}}, []core.Coverage{{
		Layer: "change", ClaimIDs: []string{claimID}, Status: "unknown",
		Detail: "The run is applying, so terminal success or failure remains pending.",
	}}, now)
	if correction := ledger.CompletionCorrection("decision_ready"); correction != "" {
		t.Fatalf("in-progress change correction = %q", correction)
	}
}

func TestLedgerAcceptsReconciledNegativeConclusions(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, Authority: core.AuthorityReadOnly,
		RequiredCoverage: []string{"application"},
	})
	claimID := contract.Claims[0].ID
	evidence := []core.Evidence{
		{ID: "ready", ClaimID: claimID, Relation: "supports", HealthEffect: "none", Confidence: "high", ObservedAt: now,
			Dimensions: map[string]string{"service": "checkout", "endpoint": "/ready", "environment": "production", "window": "now"}},
		{ID: "traffic", ClaimID: claimID, Relation: "contradicts", HealthEffect: "unhealthy", Confidence: "high", ObservedAt: now,
			Dimensions: map[string]string{"service": "checkout", "endpoint": "/pay", "environment": "production", "window": "5m"}},
	}
	coverage := []core.Coverage{{
		Layer: "application", ClaimIDs: []string{claimID}, Status: "unhealthy",
		Detail: "Readiness passes, but representative checkout traffic still fails.",
	}}
	ledger := BuildLedger(contract, evidence, coverage, now)
	view := ledger.Claims[claimID]
	if view.State != ClaimMixed || !view.Resolved || view.Detail == "" {
		t.Fatalf("claim = %+v", view)
	}
	if correction := ledger.CompletionCorrection("decision_ready"); correction != "" {
		t.Fatalf("reconciled negative correction = %q", correction)
	}

	coverage[0].Status = "healthy"
	ledger = BuildLedger(contract, evidence, coverage, now)
	if correction := ledger.CompletionCorrection("decision_ready"); !strings.Contains(correction, "contradictions") {
		t.Fatalf("healthy contradiction correction = %q", correction)
	}
}

func TestLedgerAcceptsContradictedPropositionAsUnhealthyEvidence(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, RequiredCoverage: []string{"application"},
	})
	claimID := contract.Claims[0].ID
	ledger := BuildLedger(contract, []core.Evidence{{
		ID: "failures", ClaimID: claimID, Relation: "contradicts", HealthEffect: "unhealthy", Confidence: "high", ObservedAt: now,
		Dimensions: map[string]string{"service": "checkout", "endpoint": "/pay", "environment": "production", "window": "5m"},
	}}, []core.Coverage{{
		Layer: "application", ClaimIDs: []string{claimID}, Status: "unhealthy",
		Detail: "Representative checkout requests fail consistently.",
	}}, now)
	if view := ledger.Claims[claimID]; view.State != ClaimContradicted || !view.Resolved {
		t.Fatalf("claim = %+v", view)
	}
	if correction := ledger.CompletionCorrection("decision_ready"); correction != "" {
		t.Fatalf("contradicted proposition correction = %q", correction)
	}
}

func TestLedgerRejectsPositiveEvidencePairedWithUnhealthyCoverage(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, RequiredCoverage: []string{"application"},
	})
	claimID := contract.Claims[0].ID
	ledger := BuildLedger(contract, []core.Evidence{{
		ID: "success", ClaimID: claimID, Relation: "supports", Confidence: "high", ObservedAt: now,
		Dimensions: map[string]string{"service": "checkout", "endpoint": "/pay", "environment": "production", "window": "5m"},
	}}, []core.Coverage{{
		Layer: "application", ClaimIDs: []string{claimID}, Status: "unhealthy",
		Detail: "Checkout is reported unhealthy without contradictory evidence.",
	}}, now)
	if view := ledger.Claims[claimID]; view.Resolved {
		t.Fatalf("conflicting positive claim resolved = %+v", view)
	}
}

func TestLedgerAllowsExplainedUnknownOptionalSLO(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortOperationalAssessment, RequiredCoverage: []string{"slo"},
	})
	claimID := contract.Claims[0].ID
	ledger := BuildLedger(contract, nil, []core.Coverage{{
		Layer: "slo", ClaimIDs: []string{claimID}, Status: "unknown",
		Detail: "No formal SLO exists; current user-path evidence is assessed separately.",
	}}, now)
	if view := ledger.Claims[claimID]; !view.Resolved || view.CoverageStatus != "unknown" {
		t.Fatalf("optional SLO claim = %+v", view)
	}
	if correction := ledger.CompletionCorrection("decision_ready"); correction != "" {
		t.Fatalf("optional SLO correction = %q", correction)
	}
}

func TestLedgerUsesFreshEvidenceWithoutDiscardingStaleHistory(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"host"},
	})
	ledger := BuildLedger(contract, []core.Evidence{
		{
			ID: "old", ClaimID: "host.current_state", Relation: "supports",
			ObservedAt: now.Add(-time.Hour), Confidence: "high",
			Dimensions: map[string]string{"host": "web-1", "environment": "production"},
		},
		{
			ID: "fresh", ClaimID: "host.current_state", Relation: "supports",
			ObservedAt: now.Add(-time.Minute), Confidence: "high",
			Dimensions: map[string]string{"host": "web-1", "environment": "production"},
		},
	}, []core.Coverage{{
		Layer: "host", ClaimIDs: []string{"host.current_state"}, Status: "healthy",
		Detail: "The current host is responsive.",
	}}, now)
	claim := ledger.Claims["host.current_state"]
	if claim.State != ClaimSupported || claim.Stale || len(claim.Evidence) != 1 ||
		len(claim.StaleEvidence) != 1 {
		t.Fatalf("claim = %+v", claim)
	}
	if correction := ledger.CompletionCorrection("decision_ready"); correction != "" {
		t.Fatalf("fresh claim correction = %q", correction)
	}
}
