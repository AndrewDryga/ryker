package decision

import (
	"slices"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func boundedAlertAssessment() *AlertAssessment {
	return &AlertAssessment{
		Verdict:             "confirmed_issue",
		Impact:              "Requests on the measured Rivals routes are returning errors.",
		CauseStatus:         "bounded",
		Cause:               "The failure is inside the measured Rivals request path.",
		CauseClaimIDs:       []string{"application.functional_behavior"},
		EvidenceRefs:        []string{"rivals-errors"},
		ImmediateActionKind: "mitigation",
		ImmediateAction:     "Route affected requests around the failing handler.",
		Verification:        "Repeat the measured requests and confirm they succeed.",
		LongTermSolution:    "Correct the failing handler and retain the request-path check.",
		Scope: &OperationalScope{
			Status:            "bounded",
			CheckedTargets:    []string{"Rivals routes"},
			UnverifiedTargets: []string{"other VA1 routes"},
			EvidenceRefs:      []string{"rivals-errors"},
		},
	}
}

func boundedScopeEvidence() []core.Evidence {
	return []core.Evidence{{
		ID: "rivals-errors", ClaimID: "application.functional_behavior",
		Relation: "contradicts", HealthEffect: "degraded", Target: "Rivals routes",
		SourceType: "emisar", SourceName: "VA1 request metrics",
		Observation: "The measured routes return errors.",
	}}
}

// Arbitrary completion prose cannot be the scope contract. These paraphrases all made the same
// exhaustive claim, and a finite phrase list can only catch the versions it happened to imagine.
// Once scope is structured, the host renders one bounded message independent of those words.
// Covers: TestDegradedReplyDoesNotClaimOnlyAffectedPathFromBoundedChecks
// Covers finding: 20260810T185132Z-run_cbc406b198923d271f43044f136369ff
func TestBoundedOperationalScopeMakesExclusiveParaphrasesIrrelevant(t *testing.T) {
	assessment := boundedAlertAssessment()
	want := ""
	for _, paraphrase := range []string{
		"Rivals stands alone as the unhealthy path.",
		"Every route beyond Rivals appears sound.",
		"The fault is confined to Rivals and nowhere else.",
	} {
		assessment.Impact = paraphrase
		assessment.Cause = paraphrase
		assessment.ImmediateAction = paraphrase
		assessment.Verification = paraphrase
		assessment.LongTermSolution = paraphrase
		assessment.Scope.UnverifiedTargets = []string{paraphrase}
		decision, correction := RenderOperationalAlertDecision(WatchDecision{
			Action: "reply", Message: paraphrase, AlertAssessment: assessment,
		}, boundedScopeEvidence())
		if correction != "" {
			t.Fatalf("valid bounded scope rejected: %s", correction)
		}
		if strings.Contains(decision.Message, paraphrase) {
			t.Fatalf("host retained arbitrary scope prose %q in %q", paraphrase, decision.Message)
		}
		if !strings.Contains(decision.Message, "Among the checked targets") ||
			!strings.Contains(decision.Message, "Targets outside the checked set remain unverified") {
			t.Fatalf("host did not render bounded scope: %q", decision.Message)
		}
		if want == "" {
			want = decision.Message
		} else if decision.Message != want {
			t.Fatalf("paraphrase changed host rendering:\nwant %q\n got %q", want, decision.Message)
		}
	}
}

// Covers: TestDesktopWebSocketRecoveryRequiresDesktopEvidence
// Covers: TestUnsupportedOperationalClaimRejectsServingClaimWithoutApplicationEvidence
func TestBoundedOperationalScopeRequiresEvidenceForEveryCheckedTarget(t *testing.T) {
	assessment := boundedAlertAssessment()
	if correction := OperationalScopeCorrection(assessment, boundedScopeEvidence()); correction != "" {
		t.Fatalf("bounded scope rejected: %s", correction)
	}
	assessment.Scope.CheckedTargets = append(assessment.Scope.CheckedTargets, "League routes")
	if correction := OperationalScopeCorrection(assessment, boundedScopeEvidence()); !strings.Contains(correction, "League routes") {
		t.Fatalf("missing target evidence was accepted: %q", correction)
	}
}

func TestOperationalScopeMustBeExplicitOnANewResult(t *testing.T) {
	assessment := boundedAlertAssessment()
	assessment.Scope = nil
	if correction := OperationalScopeCorrection(assessment, boundedScopeEvidence()); !strings.Contains(correction, "no structured scope") {
		t.Fatalf("missing live scope was inferred from model evidence: %q", correction)
	}
}

func TestCheckedTargetRequiresAnExplicitTypedEvidenceTarget(t *testing.T) {
	assessment := boundedAlertAssessment()
	evidence := boundedScopeEvidence()
	evidence[0].Target = ""
	evidence[0].SourceName = "Rivals routes"
	evidence[0].Dimensions = map[string]string{"service": "Rivals routes"}
	if correction := OperationalScopeCorrection(assessment, evidence); !strings.Contains(correction, "Rivals routes") {
		t.Fatalf("source prose or an arbitrary dimension satisfied target evidence: %q", correction)
	}
}

func TestExhaustiveOperationalScopeRequiresAValidatedCompleteUniverse(t *testing.T) {
	assessment := boundedAlertAssessment()
	assessment.Scope = &OperationalScope{
		Status:              "exhaustive",
		CheckedTargets:      []string{"auth", "payments"},
		EvidenceRefs:        []string{"configured-services", "auth-health", "payments-health"},
		UniverseEvidenceRef: "configured-services",
	}
	evidence := []core.Evidence{
		{
			ID: "configured-services", ClaimID: "scope.target_universe", Relation: "supports",
			SourceType: "repository", SourceName: "production service inventory",
			Observation: "The production routing inventory contains auth and payments.",
		},
		{ID: "auth-health", ClaimID: "application.functional_behavior", Relation: "supports", Target: "auth", SourceType: "emisar", SourceName: "auth health", Observation: "auth is healthy"},
		{ID: "payments-health", ClaimID: "application.functional_behavior", Relation: "supports", Target: "payments", SourceType: "emisar", SourceName: "payments health", Observation: "payments is healthy"},
	}
	if correction := OperationalScopeCorrection(assessment, evidence); !strings.Contains(correction, "host has not attested") {
		t.Fatalf("model-authored inventory unlocked exhaustive scope: %q", correction)
	}
	attestation := OperationalTargetUniverse{
		EvidenceRef: "configured-services", Targets: []string{"auth", "payments"},
	}
	if correction := OperationalScopeCorrectionWithUniverse(assessment, evidence, &attestation); correction != "" {
		t.Fatalf("complete exhaustive scope rejected: %s", correction)
	}
	rendered, correction := RenderOperationalAlertDecision(WatchDecision{
		Action: "reply", Message: "arbitrary", AlertAssessment: assessment,
	}, evidence, &attestation)
	if correction != "" {
		t.Fatalf("validated exhaustive rendering rejected: %s", correction)
	}
	if !strings.Contains(rendered.Message, "All configured targets were checked") {
		t.Fatalf("exhaustive scope was not rendered: %q", rendered.Message)
	}

	inventoryOnlyAssessment := *assessment
	inventoryOnlyScope := *assessment.Scope
	inventoryOnlyScope.EvidenceRefs = []string{"configured-services"}
	inventoryOnlyAssessment.Scope = &inventoryOnlyScope
	withoutChecks := append([]core.Evidence(nil), evidence[:1]...)
	if correction := OperationalScopeCorrectionWithUniverse(
		&inventoryOnlyAssessment, withoutChecks, &attestation,
	); !strings.Contains(correction, "auth") {
		t.Fatalf("inventory alone was accepted as per-target health evidence: %q", correction)
	}

	attestation.Targets = []string{"auth", "payments", "search"}
	correction = OperationalScopeCorrectionWithUniverse(assessment, evidence, &attestation)
	if !strings.Contains(correction, "search") ||
		!slices.Equal(assessment.Scope.CheckedTargets, []string{"auth", "payments"}) {
		t.Fatalf("incomplete exhaustive scope was accepted: %q", correction)
	}
}

// Covers: TestScopedRepositorySearchCannotBecomeCategoricalOwnershipExclusion
func TestDeepOperationalReportCarriesAndRendersStructuredScope(t *testing.T) {
	raw := `{"operations":[
		{"id":"rivals-errors","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"route health","observation":"the checked route returns errors","relation":"contradicts","health_effect":"degraded","source_type":"monitoring","source_name":"route probe","target":"Rivals routes"}},
		{"id":"alert","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue","impact":"Every other route is healthy.","cause_status":"bounded","cause":"The failure exists nowhere else.","cause_claim_ids":["application.functional_behavior"],"evidence_refs":["rivals-errors"],"immediate_action_kind":"mitigation","immediate_action":"Treat all other systems as healthy.","verification":"Nothing else needs checking.","long_term_solution":"No other work is needed.","scope":{"status":"bounded","checked_targets":["Rivals routes"],"unverified_targets":["other VA1 routes"],"evidence_refs":["rivals-errors"]}}},
		{"id":"complete","type":"complete_episode","completion":{"message":"Rivals is the sole unhealthy route.","completion":{"status":"decision_ready","verdict":"degraded","summary":"The checked route is degraded."}}}
	]}`
	report, err := DecodeAgentReport(raw)
	if err != nil {
		t.Fatal(err)
	}
	if report.AlertAssessment == nil {
		t.Fatal("deep report lost its structured alert assessment")
	}
	report, correction := RenderOperationalAlertReport(report, report.Evidence)
	if correction != "" {
		t.Fatalf("deep report scope rejected: %s", correction)
	}
	for _, unsupported := range []string{
		"Every other route is healthy", "nowhere else", "all other systems",
		"Nothing else", "No other work", "sole unhealthy",
	} {
		if strings.Contains(report.Message, unsupported) {
			t.Fatalf("deep report retained unsupported prose %q in %q", unsupported, report.Message)
		}
	}
	if !strings.Contains(report.Message, "Among the checked targets") {
		t.Fatalf("deep report lacks host-rendered bounded scope: %q", report.Message)
	}
}
