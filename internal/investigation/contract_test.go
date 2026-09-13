package investigation

import (
	"maps"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
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
		"record_evidence", "complete_episode", "published semantic replacement",
		"reusable workflow as a reproducibility or maintenance gap",
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

func TestCompileSeparatesRecoveryAndRunbookWorkFromChangeReview(t *testing.T) {
	recovery := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Authority: core.AuthorityReadOnly,
		Objective:        "Assess whether checkout recovered after the deployment",
		RequiredCoverage: []string{"change", "application"},
	})
	if recovery.Completion.ConclusionKind != "operational_health" ||
		!slices.Contains(recovery.Completion.AllowedVerdicts, "unhealthy") {
		t.Fatalf("recovery contract = %+v", recovery.Completion)
	}

	runbook := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Authority: core.AuthorityGovernedOperation,
		Objective:        "Extend and test the daily runbook",
		RequiredCoverage: []string{"task"},
	})
	if runbook.Completion.ConclusionKind != "factual_assessment" ||
		slices.Contains(runbook.Completion.AllowedVerdicts, "degraded") {
		t.Fatalf("runbook contract = %+v", runbook.Completion)
	}
}

func TestFactualTaskDraftIsDecisionReadyWithoutPublication(t *testing.T) {
	now := time.Date(2026, 8, 3, 15, 5, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Objective: "Extend and test the daily runbook",
		RequiredCoverage: []string{"task"},
	})
	claimID := contract.Claims[0].ID
	ledger := BuildLedger(contract, []core.Evidence{{
		ClaimID: claimID, Relation: "supports", HealthEffect: "none",
		SourceType: "emisar", SourceName: "runbook draft",
		Observation: "The 32-check draft passed validation and focused smoke tests.",
		ObservedAt:  now, Confidence: "high",
		Dimensions: map[string]string{"artifact": "daily-health", "revision": "v4"},
	}}, []core.Coverage{{
		Layer: "task", ClaimIDs: []string{claimID}, Status: "healthy",
		Detail: "The requested extension and validation are complete; publication was not requested.",
	}}, now)
	if correction := ledger.CompletionCorrectionFor("decision_ready", "confirmed"); correction != "" {
		t.Fatalf("validated draft rejected: %q", correction)
	}
}

func TestLedgerAllowsDecisiveNegativeHealthWithBoundedSecondaryUnknown(t *testing.T) {
	now := time.Date(2026, 8, 2, 13, 5, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Authority: core.AuthorityReadOnly,
		Objective:        "Assess whether checkout recovered after the deployment",
		RequiredCoverage: []string{"change", "application"},
	})
	evidence := []core.Evidence{{
		ClaimID: "application.functional_behavior", Relation: "contradicts",
		HealthEffect: "unhealthy", SourceType: "monitoring", SourceName: "request errors",
		Observation: "POST /checkout errors are 8.4 percent versus a 0.3 percent baseline.",
		ObservedAt:  now, Confidence: "high",
		Dimensions: map[string]string{
			"service": "checkout", "endpoint": "POST /checkout",
			"environment": "production", "window": "10m",
		},
	}}
	coverage := []core.Coverage{
		{Layer: "change", Status: "unknown", Detail: "The deployed diff is unavailable."},
		{Layer: "application", Status: "unhealthy", Detail: "Representative checkout requests fail."},
	}
	ledger := BuildLedger(contract, evidence, coverage, now)
	if correction := ledger.CompletionCorrectionFor("decision_ready", "unhealthy"); correction != "" {
		t.Fatalf("decisive negative result rejected: %q", correction)
	}
	if correction := ledger.CompletionCorrectionFor("decision_ready", "healthy"); correction == "" {
		t.Fatal("healthy result accepted with unknown change evidence")
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
		Effort: core.EffortFocusedCheck, Objective: "Review this Terraform plan",
		RequiredCoverage: []string{"change"},
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

// A handful of successful point probes cannot establish platform-wide
// application health. The successful sibling records the two exact scopes and
// the equivalent-window error and timeout indicators that the scheduled health
// contract asks for; these are typed dimensions, not phrases recovered from
// model prose.
// Covers: TestHealthyAssessmentRequiresComparableApplicationTrendEvidence
// Covers finding: 20260810T150529Z-run_b7706a1c89c3a252c0392bdcd0058e92
func TestHealthyAssessmentRequiresComparableApplicationTrendEvidence(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	episode := core.WorkEpisode{
		Effort:           core.EffortOperationalAssessment,
		RequiredCoverage: []string{"application", "slo"},
	}
	probe := core.Evidence{
		ID: "probe", ClaimID: "application.functional_behavior",
		Relation: "supports", HealthEffect: "none", SourceType: "monitoring",
		SourceName: "HTTP probe", Observation: "Three bounded endpoints returned 200.",
		ObservedAt: now, Dimensions: map[string]string{
			"service": "platform", "endpoint": "/,/api/a,/api/b",
			"environment": "production", "window": "point-in-time",
			"measurement_kind": "functional_probe",
		},
	}
	coverage := []core.Coverage{
		{Layer: "application", ClaimIDs: []string{"application.functional_behavior"}, Status: "healthy", Detail: "Three bounded endpoints returned 200."},
		{Layer: "slo", ClaimIDs: []string{"impact.current"}, Status: "healthy", Detail: "No formal SLO exists."},
	}
	completion := &CompletionAssessment{
		Status: "decision_ready", Verdict: "healthy", Summary: "The platform is healthy.",
	}
	if correction := ClaimCorrection(
		episode, "reply", []core.Evidence{probe}, coverage, completion, now, now, true,
	); !strings.Contains(correction, "equivalent-window") {
		t.Fatalf("bounded HTTP probes did not request comparable trends: %q", correction)
	}

	evidence := []core.Evidence{probe}
	for _, item := range []struct {
		id, scope, kind, service string
	}{
		{"broad-errors", "broad", "error_rate", "platform"},
		{"broad-timeouts", "broad", "timeout_rate", "platform"},
		{"service-errors", "service", "error_rate", "checkout"},
		{"service-timeouts", "service", "timeout_rate", "checkout"},
	} {
		evidence = append(evidence, core.Evidence{
			ID: item.id, ClaimID: "application.functional_behavior",
			Relation: "supports", HealthEffect: "none", SourceType: "monitoring",
			SourceName: "VictoriaMetrics", Observation: "Equivalent windows show no spike.",
			ObservedAt: now, Dimensions: map[string]string{
				"service": item.service, "endpoint": "all requests",
				"environment": "production", "window": "15m",
				"comparison_window": "previous 15m", "population": "all requests",
				"denominator": "requests", "measurement_scope": item.scope,
				"measurement_kind": item.kind,
			},
		})
	}
	coverage[1].Status = "not_applicable"
	coverage[1].Detail = "No formal SLO exists; current operational indicators are assessed in application coverage."
	if correction := ClaimCorrection(
		episode, "reply", evidence, coverage, completion, now, now, true,
	); correction != "" {
		t.Fatalf("equivalent-window functional and trend evidence was rejected: %q", correction)
	}

	// Presence is not comparability. This is the exact false green the first
	// implementation admitted: each bucket was populated, but error and timeout
	// rates described different populations and windows.
	mismatched := append([]core.Evidence(nil), evidence...)
	mismatched[len(mismatched)-1].Dimensions = maps.Clone(mismatched[len(mismatched)-1].Dimensions)
	mismatched[len(mismatched)-1].Dimensions["window"] = "24h"
	mismatched[len(mismatched)-1].Dimensions["population"] = "background jobs"
	if correction := ClaimCorrection(
		episode, "reply", mismatched, coverage, completion, now, now, true,
	); !strings.Contains(correction, "do not share") {
		t.Fatalf("incompatible trend signatures counted as equivalent: %q", correction)
	}

	stale := append([]core.Evidence(nil), evidence...)
	for index := range stale {
		stale[index].ObservedAt = now.Add(-time.Hour)
	}
	if correction := ClaimCorrection(
		episode, "reply", stale, coverage, completion, now, now, true,
	); !strings.Contains(correction, "fresh") {
		t.Fatalf("stale health rows satisfied a current verdict: %q", correction)
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

func TestLedgerAcceptsTerminalChangeFailureWithUnknownPartialEffects(t *testing.T) {
	now := time.Date(2026, 8, 4, 23, 31, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"change"},
		Objective: "Review Terraform run run-6d2hQfNJrTeyAP4T",
	})
	claimID := contract.Claims[0].ID
	ledger := BuildLedger(contract, []core.Evidence{{
		ID: "terminal-run", ClaimID: claimID, Relation: "contradicts",
		SourceType: "emisar", SourceName: "tfc.run_details", Confidence: "high",
		ObservedAt: now, Observation: "The exact run is terminally errored after apply began.",
		Dimensions: map[string]string{
			"repository": "SME-Blitz/blitz-infra", "environment": "production",
			"revision": "ddd526f",
		},
	}}, []core.Coverage{{
		Layer: "change", ClaimIDs: []string{claimID}, Status: "unhealthy",
		Detail: "The apply failed; partial effects still require state reconciliation.",
	}}, now)
	if correction := ledger.CompletionCorrectionFor("decision_ready", "failed"); correction != "" {
		t.Fatalf("terminal failure correction = %q", correction)
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

func TestLedgerLetsNewerCorrelatedEvidenceSupersedeContradictoryHistory(t *testing.T) {
	now := time.Date(2026, 8, 5, 21, 55, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"application"},
	})
	claimID := contract.Claims[0].ID
	dimensions := map[string]string{
		"service": "monitoring", "environment": "production", "window": "5m",
	}
	ledger := BuildLedger(contract, []core.Evidence{
		{
			ID: "older", ClaimID: claimID, Relation: "supports", SourceType: "emisar",
			SourceID: "monitoring-check", SourceName: "service probe",
			ObservedAt: now.Add(-5 * time.Minute), Confidence: "high",
			Observation: "The service responds normally.", Dimensions: dimensions,
		},
		{
			ID: "newer", ClaimID: claimID, Relation: "contradicts", SourceType: "emisar",
			SourceID: "monitoring-check", SourceName: "service probe",
			ObservedAt: now, Confidence: "high", HealthEffect: "unhealthy",
			Observation: "The service now returns errors.", Dimensions: dimensions,
		},
	}, []core.Coverage{{
		Layer: "application", ClaimIDs: []string{claimID}, Status: "unhealthy",
		ObservedAt: now, Detail: "The latest service probe fails.",
	}}, now)
	claim := ledger.Claims[claimID]
	if claim.State != ClaimContradicted || len(claim.Contradictions) != 1 ||
		claim.Contradictions[0].ID != "newer" || len(claim.StaleEvidence) != 1 {
		t.Fatalf("correlated claim ledger = %+v", claim)
	}
}

// A claim whose contradiction is older than every supporting observation has
// recovered, and a healthy verdict must be reachable.
//
// This is the deadlock that cost forty-four episodes ninety-two continuation
// turns. Correlation-based staleness keys on the source id and every dimension
// value, so evidence about the revision that fixed a rollout never supersedes
// evidence about the revision that broke it — the change itself keeps the two
// records apart. The claim stayed mixed forever, a mixed claim could only
// resolve through a material health effect, and a material health effect needs
// a degraded or unhealthy status. The host asked for a resolution the model
// had already supplied, and kept asking.
func TestRecoveredClaimStopsBlockingAHealthyVerdict(t *testing.T) {
	now := time.Date(2026, 8, 12, 15, 8, 0, 0, time.UTC)
	// change.recent, deliberately: it carries no freshness bound, so a
	// contradiction never ages out of it, and its dimensions include the
	// revision — the one value guaranteed to differ between the evidence that
	// found a problem and the evidence that found it fixed. Thirty-two of the
	// stuck claims were this one.
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"change"},
	})
	claimID := ""
	for _, requirement := range contract.Claims {
		if requirement.ID == "change.recent" {
			claimID = requirement.ID
		}
	}
	if claimID == "" {
		t.Fatal("the change.recent claim is no longer in a focused check")
	}
	ledgerFor := func(supportAt, contradictAt time.Time) Ledger {
		return BuildLedger(contract, []core.Evidence{
			{
				ID: "broke", ClaimID: claimID, Relation: "contradicts", SourceType: "emisar",
				SourceID: "run-older", SourceName: "HCP Terraform run",
				ObservedAt: contradictAt, Confidence: "high",
				Observation: "The earlier rollout left one allocation unhealthy.",
				Dimensions: map[string]string{
					"environment": "production", "repository": "blitz-infra", "revision": "aaaa1111",
				},
			},
			{
				ID: "fixed", ClaimID: claimID, Relation: "supports", SourceType: "emisar",
				SourceID: "run-newer", SourceName: "HCP Terraform run",
				ObservedAt: supportAt, Confidence: "high",
				Observation: "Revision 6942aec8 rolled out 4 of 4 successfully.",
				Dimensions: map[string]string{
					"environment": "production", "repository": "blitz-infra", "revision": "6942aec8",
				},
			},
		}, []core.Coverage{{
			Layer: "change", ClaimIDs: []string{claimID}, Status: "healthy",
			ObservedAt: now, Detail: "The failed rollout was replaced by a successful one.",
		}}, now)
	}

	// The revision changed, so the two records never correlate and the claim
	// is genuinely mixed rather than superseded.
	recovered := ledgerFor(now.Add(-4*time.Minute), now.Add(-2*time.Hour))
	if state := recovered.Claims[claimID].State; state != ClaimMixed {
		t.Fatalf("claim state = %v, want the mixed state this fix is about", state)
	}
	if blocker := recovered.CompletionCorrection("healthy"); blocker != "" {
		t.Fatalf("a recovered claim still blocks a healthy verdict: %q", blocker)
	}

	// The guard has to survive where it earns its keep: a contradiction that
	// is the newest thing known is a disagreement about now.
	live := ledgerFor(now.Add(-2*time.Hour), now.Add(-4*time.Minute))
	if blocker := live.CompletionCorrection("healthy"); blocker == "" {
		t.Fatal("a contradiction newer than its support let a healthy verdict through")
	}
}

// An observation with no recorded instant cannot be shown to be history, so it
// keeps blocking. "We do not know when this was seen" reads as "it may be now".
func TestContradictionWithNoObservationTimeStillBlocks(t *testing.T) {
	now := time.Date(2026, 8, 12, 15, 8, 0, 0, time.UTC)
	contract := Compile(core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"application"},
	})
	claimID := contract.Claims[0].ID
	ledger := BuildLedger(contract, []core.Evidence{
		{
			ID: "undated", ClaimID: claimID, Relation: "contradicts", SourceType: "emisar",
			SourceID: "run-older", SourceName: "probe", Confidence: "high",
			Observation: "Something was wrong, at an unrecorded moment.",
		},
		{
			ID: "fixed", ClaimID: claimID, Relation: "supports", SourceType: "emisar",
			SourceID: "run-newer", SourceName: "probe", ObservedAt: now.Add(-time.Minute),
			Confidence: "high", Observation: "It responds normally now.",
		},
	}, []core.Coverage{{
		Layer: "application", ClaimIDs: []string{claimID}, Status: "healthy",
		ObservedAt: now, Detail: "Checked and healthy.",
	}}, now)
	if blocker := ledger.CompletionCorrection("healthy"); blocker == "" {
		t.Fatal("an undated contradiction was treated as history")
	}
}
