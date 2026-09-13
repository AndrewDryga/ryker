package decision

import (
	"slices"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
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
		assessment.LongTermSolution = paraphrase
		assessment.Scope.UnverifiedTargets = []string{"other VA1 routes"}
		decision, correction := RenderOperationalAlertDecision(WatchDecision{
			Action: "reply", Message: paraphrase, AlertAssessment: assessment,
		}, boundedScopeEvidence())
		if correction != "" {
			t.Fatalf("valid bounded scope rejected: %s", correction)
		}
		if strings.Contains(decision.Message, paraphrase) {
			t.Fatalf("host retained arbitrary scope prose %q in %q", paraphrase, decision.Message)
		}
		if !strings.Contains(decision.Message, "I haven’t yet verified other VA1 routes") {
			t.Fatalf("host did not render bounded scope: %q", decision.Message)
		}
		if want == "" {
			want = decision.Message
		} else if decision.Message != want {
			t.Fatalf("paraphrase changed host rendering:\nwant %q\n got %q", want, decision.Message)
		}
	}
}

// The 2026-08-20 Host OOM reply had already established the killed process,
// cgroup boundary, surviving allocation, and current HTTP behavior. Render
// replaced every one of those facts with "the checked evidence confirms an
// active issue", leaving the operator with less information than the ledger.
// Validated evidence is the public result; structured scope bounds it.
// Covers: TestOperationalAlertReplyStatesIdentifiedCauseAndMitigation
// Covers: TestOperationalAlertReplyRetainsEvidenceBackedCauseAndAction
// Covers: TestIdentifiedOperationalCauseAndMitigationReachSlackReply
func TestOperationalAlertRendersTheConcreteValidatedAssessment(t *testing.T) {
	assessment := boundedAlertAssessment()
	assessment.Impact = "A Node.js worker in the website allocation was OOM-killed; the allocation is running and fresh website requests succeed."
	assessment.Cause = "The worker reached its memory-cgroup limit; host memory pressure was not the cause."
	assessment.ImmediateAction = "Inspect the allocation restart event and current task memory before changing the limit."
	assessment.Verification = "Confirm the restart count, current memory headroom, and representative website health."
	assessment.Scope.CheckedTargets = []string{"website allocation on nomad-hvn01"}
	assessment.Scope.UnverifiedTargets = []string{"request impact during the kill", "the memory-growth mechanism"}
	assessment.EvidenceRefs = []string{"website-oom", "website-cause"}
	assessment.Scope.EvidenceRefs = []string{"website-oom", "website-cause"}
	evidence := []core.Evidence{
		{
			ID: "website-oom", ClaimID: "workload.desired_state", Relation: "contradicts",
			HealthEffect: "degraded", Target: "website allocation on nomad-hvn01",
			SourceType: "emisar", SourceName: "Nomad allocation inspection",
			Observation: assessment.Impact,
		},
		{
			ID: "website-cause", ClaimID: "host.current_state", Relation: "contradicts",
			HealthEffect: "degraded", Target: "website allocation on nomad-hvn01",
			SourceType: "emisar", SourceName: "kernel cgroup inspection",
			Observation: assessment.Cause,
		},
	}

	rendered, correction := RenderOperationalAlertDecision(WatchDecision{
		Action: "reply", Message: "generic model completion", AlertAssessment: assessment,
	}, evidence)
	if correction != "" {
		t.Fatalf("validated OOM assessment rejected: %s", correction)
	}
	for _, want := range []string{
		assessment.Impact,
		assessment.Cause,
		assessment.ImmediateAction,
		"request impact during the kill",
		"the memory-growth mechanism",
	} {
		if !strings.Contains(rendered.Message, want) {
			t.Fatalf("rendered assessment lost %q:\n%s", want, rendered.Message)
		}
	}
	for _, boilerplate := range []string{
		"The checked evidence confirms an active issue",
		"Targets outside the checked set remain unverified",
		"Mitigate the affected checked targets",
		"**Checked:**",
		"**What I found:**",
		"**Still unknown:**",
		"**Success check:**",
	} {
		if strings.Contains(rendered.Message, boilerplate) {
			t.Fatalf("rendered assessment retained boilerplate %q:\n%s", boilerplate, rendered.Message)
		}
	}
}

// The first correct VictoriaLogs replay printed seven evidence records as
// seven paragraphs. Scheduler repeated workload state, and impact repeated the
// application error check, turning a 17-second restart into a wall of text.
// The public reply keeps causal evidence plus one result per operational layer.
func TestOperationalAlertCollapsesDuplicateRuntimeEvidence(t *testing.T) {
	assessment := boundedAlertAssessment()
	assessment.EvidenceRefs = []string{"oom"}
	assessment.Scope = &OperationalScope{
		Status: "bounded",
		CheckedTargets: []string{
			"kernel event", "allocation", "scheduler", "service errors", "impact",
		},
		UnverifiedTargets: []string{"requests during the restart"},
		EvidenceRefs:      []string{"oom", "workload", "scheduler", "application", "impact"},
	}
	evidence := []core.Evidence{
		{ID: "oom", ClaimID: "host.current_state", Relation: "contradicts", Target: "kernel event", Observation: "The kernel OOM-killed VictoriaLogs."},
		{ID: "workload", ClaimID: "workload.desired_state", Relation: "supports", Target: "allocation", Observation: "The allocation restarted and is running."},
		{ID: "scheduler", ClaimID: "scheduler.desired_state", Relation: "supports", Target: "scheduler", Observation: "Nomad reports the allocation running."},
		{ID: "application", ClaimID: "application.functional_behavior", Relation: "supports", Target: "service errors", Observation: "Current service errors are zero."},
		{ID: "impact", ClaimID: "impact.current", Relation: "supports", Target: "impact", Observation: "The current error increase is zero."},
	}
	rendered, correction := RenderOperationalAlertDecision(WatchDecision{
		Action: "reply", AlertAssessment: assessment,
	}, evidence)
	if correction != "" {
		t.Fatalf("valid assessment rejected: %s", correction)
	}
	for _, want := range []string{
		"The kernel OOM-killed VictoriaLogs.",
		"Allocation and service errors look healthy.",
		"I haven’t yet verified requests during the restart.",
	} {
		if !strings.Contains(rendered.Message, want) {
			t.Fatalf("rendered alert lost %q:\n%s", want, rendered.Message)
		}
	}
	for _, duplicate := range []string{
		"The allocation restarted and is running.",
		"Nomad reports the allocation running.",
		"Current service errors are zero.",
		"The current error increase is zero.",
	} {
		if strings.Contains(rendered.Message, duplicate) {
			t.Fatalf("rendered alert repeated %q:\n%s", duplicate, rendered.Message)
		}
	}
}

// The Valorant Flutter investigation led with a successful backend probe and
// two paragraphs of server metrics before it mentioned the client failure that
// opened the alert. It then printed the scope ledger verbatim. The public reply
// must start with the affected signal, use healthy checks as contrast, and keep
// the machine-readable target inventory out of conversational prose.
func TestOperationalAlertLeadsWithAffectedSignalNotSuccessfulChecks(t *testing.T) {
	assessment := boundedAlertAssessment()
	assessment.EvidenceRefs = []string{"backend-health", "backend-rates", "client-errors", "infra-change"}
	assessment.Scope = &OperationalScope{
		Status: "bounded",
		CheckedTargets: []string{
			"declared Valorant backend image", "Valorant backend health endpoint",
			"Valorant backend HTTP outcomes", "Valorant Flutter client request failures",
		},
		UnverifiedTargets: []string{
			"current fingerprint rate", "failed Flutter request path", "affected client build",
		},
		EvidenceRefs: []string{"infra-change", "backend-health", "backend-rates", "client-errors"},
	}
	assessment.ImmediateAction = "Inspect the Flutter HTTP wrapper and current fingerprint events."
	assessment.Verification = "Confirm the fingerprint stops while backend health remains normal."
	evidence := []core.Evidence{
		{ID: "backend-health", ClaimID: "application.functional_behavior", Relation: "supports", HealthEffect: "none", Target: "Valorant backend health endpoint", Observation: "A governed probe returned HTTP 200 in 70 ms."},
		{ID: "backend-rates", ClaimID: "impact.current", Relation: "supports", HealthEffect: "none", Target: "Valorant backend HTTP outcomes", Observation: "Backend 499 and 502 responses remained zero."},
		{ID: "client-errors", ClaimID: "impact.current", Relation: "contradicts", HealthEffect: "degraded", Target: "Valorant Flutter client request failures", Observation: "Better Stack recorded 69 Valorant Flutter HTTP request failures under fingerprint 92803b2."},
		{ID: "infra-change", ClaimID: "change.recent", Relation: "supports", HealthEffect: "risk", SourceType: "repository", Target: "declared Valorant backend image", Observation: "The declared backend image tag changed before the alert window, but deployment timing is unknown."},
	}
	rendered, correction := RenderOperationalAlertDecision(WatchDecision{
		Action: "reply", AlertAssessment: assessment,
	}, evidence)
	if correction != "" {
		t.Fatalf("valid bounded assessment rejected: %s", correction)
	}
	firstLine, _, _ := strings.Cut(rendered.Message, "\n")
	if !strings.Contains(firstLine, evidence[2].Observation) {
		t.Fatalf("reply did not lead with the affected client signal:\n%s", rendered.Message)
	}
	healthyContrast := "Valorant backend health endpoint and Valorant backend HTTP outcomes look healthy."
	affectedAt := strings.Index(rendered.Message, evidence[2].Observation)
	healthyAt := strings.Index(rendered.Message, healthyContrast)
	if healthyAt < 0 {
		t.Fatalf("reply did not turn successful backend checks into useful contrast:\n%s", rendered.Message)
	}
	if affectedAt > healthyAt {
		t.Fatalf("successful checks preceded the affected signal:\n%s", rendered.Message)
	}
	for _, bureaucratic := range []string{
		"I checked 4 targets", "declared Valorant backend image, Valorant backend health endpoint",
		"Verification:", "A governed probe returned", "Backend 499 and 502 responses",
	} {
		if strings.Contains(rendered.Message, bureaucratic) {
			t.Fatalf("reply retained ledger prose %q:\n%s", bureaucratic, rendered.Message)
		}
	}
	if !strings.Contains(rendered.Message, "I haven’t yet verified current fingerprint rate") ||
		!strings.Contains(rendered.Message, "Next: Inspect the Flutter HTTP wrapper") {
		t.Fatalf("reply lost the concise uncertainty or active next step:\n%s", rendered.Message)
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

// The 2026-08-20 Host OOM follow-up scoped its conclusion to the website but
// also placed a fresh VictoriaLogs OOM inside scope.evidence_refs. A synthetic
// website summary then satisfied the one matching-target check, allowing two
// different killed processes to become one conclusion. Comparison evidence may
// inform an assessment; it cannot silently widen the checked scope.
func TestOperationalScopeRejectsEvidenceForAnotherOOMTarget(t *testing.T) {
	assessment := boundedAlertAssessment()
	assessment.Scope.CheckedTargets = []string{"website workload OOM event"}
	assessment.Scope.UnverifiedTargets = []string{"other workload OOM events"}
	assessment.Scope.EvidenceRefs = []string{"website-oom", "victorialogs-oom"}
	evidence := []core.Evidence{
		{
			ID: "website-oom", ClaimID: "host.current_state", Relation: "contradicts",
			Target: "website workload OOM event", SourceType: "emisar", SourceName: "kernel log",
			Observation: "The kernel killed a Node.js worker in the website cgroup.",
		},
		{
			ID: "victorialogs-oom", ClaimID: "impact.current", Relation: "contradicts",
			Target: "VictoriaLogs OOM event", SourceType: "emisar", SourceName: "kernel log",
			Observation: "The kernel later killed victoria-logs-p in a different cgroup.",
		},
	}
	correction := OperationalScopeCorrection(assessment, evidence)
	if !strings.Contains(correction, "victorialogs-oom") ||
		!strings.Contains(correction, "outside its checked targets") {
		t.Fatalf("different OOM targets were accepted into one scope: %q", correction)
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
	if strings.Contains(rendered.Message, "I haven’t") {
		t.Fatalf("exhaustive scope was rendered as incomplete: %q", rendered.Message)
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
		{"id":"alert","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue","impact":"Every other route is healthy.","cause_status":"bounded","cause":"The failure exists nowhere else.","cause_claim_ids":["application.functional_behavior"],"evidence_refs":["rivals-errors"],"immediate_action_kind":"mitigation","immediate_action":"Route the checked Rivals requests around the failing handler.","verification":"Repeat the checked Rivals requests and confirm they succeed.","long_term_solution":"No other work is needed.","scope":{"status":"bounded","checked_targets":["Rivals routes"],"unverified_targets":["other VA1 routes"],"evidence_refs":["rivals-errors"]}}},
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
		"Every other route is healthy", "nowhere else", "No other work", "sole unhealthy",
	} {
		if strings.Contains(report.Message, unsupported) {
			t.Fatalf("deep report retained unsupported prose %q in %q", unsupported, report.Message)
		}
	}
	if !strings.Contains(report.Message, "I haven’t yet verified other VA1 routes") {
		t.Fatalf("deep report lacks host-rendered bounded scope: %q", report.Message)
	}
}
