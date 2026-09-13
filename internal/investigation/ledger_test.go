package investigation

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

// The correction used to be the claim id and nothing else, so the model was
// told two of its own observations conflicted and not which two. It had to
// guess which one to supersede, and guessing wrong cost a whole turn — thirty
// of these in two days, on episodes that then spent every attempt they had.
func TestContradictionCorrectionNamesWhatDisagrees(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	view := ClaimView{
		Requirement: ClaimRequirement{ID: "change.recent", Layer: "change", Required: true},
		State:       ClaimMixed,
		Evidence: []core.Evidence{{
			Observation: "The deployed revision matches the requested one.",
			SourceName:  "blitz-infra", ObservedAt: now.Add(-2 * time.Minute),
		}},
		Contradictions: []core.Evidence{{
			Observation: "The running pods still report the previous revision.",
			SourceName:  "emisar", ObservedAt: now.Add(-30 * time.Minute),
		}},
	}
	detail, nameable := contradictionDetail(view)
	if !nameable {
		t.Fatalf("a quotable disagreement was judged unnameable: %+v", view)
	}
	for _, want := range []string{
		"change.recent", "deployed revision matches", "contradicted by",
		"still report the previous revision", "emisar",
	} {
		if !strings.Contains(detail, want) {
			t.Fatalf("contradiction detail %q does not name %q", detail, want)
		}
	}

	// With nothing recorded to quote there is no conflict to describe, so it
	// says so and the caller states the claim's coverage instead of producing a
	// sentence with a hole in it.
	bare := ClaimView{Requirement: ClaimRequirement{ID: "slo.error_budget"}, State: ClaimMixed}
	if got, nameable := contradictionDetail(bare); nameable {
		t.Fatalf("a claim with nothing recorded produced a conflict clause: %q", got)
	}
}

// recordedUnknownChangeCoverage and recordedChangeSupport are one claim's rows
// from the eval-prompts run of 2026-08-15T08:13Z, case "coverage statuses come
// from the allowed set". The model could not read a deployed commit SHA off the
// running site, said so in the coverage detail, and recorded what it could see.
func recordedUnknownChangeCoverage() core.Coverage {
	return core.Coverage{
		Layer: "change", ClaimIDs: []string{"change.recent"}, Status: "unknown",
		Detail: "Repository HEAD identifies intended revision and production serves version " +
			"0.40.0, but the deployed commit SHA is not exposed, so exact rollout correlation " +
			"remains unknown.",
		ObservedAt: time.Date(2026, 8, 15, 8, 35, 10, 0, time.UTC),
	}
}

func recordedChangeSupport() core.Evidence {
	return core.Evidence{
		ID: "evidence-change-live", ClaimID: "change.recent",
		Claim: "The observed state is consistent with the intended current revision and recent rollout.",
		Observation: "The live production homepage responded successfully and identified itself " +
			"as version 0.40.0, but did not expose its immutable source revision.",
		Relation: "supports", HealthEffect: "none",
		SourceType: "monitoring", SourceID: "https://emisar.dev/",
		SourceName: "Public production homepage",
		ObservedAt: time.Date(2026, 8, 15, 8, 34, 40, 0, time.UTC),
		Freshness:  "live check under 2 minutes old", Confidence: "high",
		Dimensions: map[string]string{
			"repository": "emisar", "environment": "production",
			"revision": "version 0.40.0; commit SHA unavailable",
		},
	}
}

func changeClaimContract(conclusionKind string) InvestigationContract {
	return InvestigationContract{
		Claims: []ClaimRequirement{{
			ID: "change.recent", Layer: "change", Required: true,
			Freshness: FreshnessRequirement{Class: "current_revision"},
		}},
		Completion: CompletionRule{
			ConclusionKind:  conclusionKind,
			AllowUnknownSLO: conclusionKind == "operational_health",
		},
	}
}

// Recording supporting evidence never closes an exit the same claim had without
// it.
//
// Two validators held two rules. claimResolution resolved an UNKNOWN claim on
// unknown coverage for factual_assessment and never a SUPPORTED one, so a claim
// with nothing recorded against it closed and the same claim with a supporting
// observation stayed open — the model was refused for having done more work.
// change_review had the same incoherence pointing the other way: evidence
// opened an exit that the bare claim did not have. Meanwhile
// unknownCoverageCorrection permitted unknown coverage for operational_health
// outright, so the model was told it could rest on an unknown layer and then
// told by the ledger that it could not. c07462c made the refusal say which
// validator was refusing; this makes them stop disagreeing.
//
// The rows are harvested whole from the 2026-08-15T08:13Z eval-prompts run.
func TestSupportingEvidenceNeverClosesAnExitTheBareClaimHad(t *testing.T) {
	now := time.Date(2026, 8, 15, 8, 40, 0, 0, time.UTC)
	coverage := []core.Coverage{recordedUnknownChangeCoverage()}
	for _, kind := range []string{
		"operational_health", "change_review", "factual_assessment",
		"engineering_result", "direct_answer",
	} {
		contract := changeClaimContract(kind)
		bare := BuildLedger(contract, nil, coverage, now).Claims["change.recent"]
		supported := BuildLedger(
			contract, []core.Evidence{recordedChangeSupport()}, coverage, now,
		).Claims["change.recent"]
		if supported.State != ClaimSupported {
			t.Fatalf("%s: recorded support did not make the claim supported: %s", kind, supported.State)
		}
		if bare.Resolved && !supported.Resolved {
			t.Errorf(
				"%s: the claim closes with no evidence and stays open once the model records "+
					"support for it; recording evidence narrowed its exits",
				kind,
			)
		}
	}
}

// The rule that both validators now share, kind by kind. An unknown coverage
// row is an answer exactly where the conclusion has a verdict resting on an
// unknown — a change review calls that in_progress or inconclusive, and a
// factual assessment calls it inconclusive or not_confirmed.
//
// operational_health is deliberately not on that list and the assertion below
// holds it shut. For an incident investigation the ledger is the ONLY guard:
// CompletionCorrection runs operationalHealthVerdictCorrection only when the
// effort is an operational assessment, so nothing else stops the recorded
// envelope this test's rows came from — a healthy verdict resting on a change
// layer the model had just written down as unknown.
func TestUnknownCoverageAnswersOnlyTheConclusionsThatRestOnOne(t *testing.T) {
	now := time.Date(2026, 8, 15, 8, 40, 0, 0, time.UTC)
	coverage := []core.Coverage{recordedUnknownChangeCoverage()}
	evidence := []core.Evidence{recordedChangeSupport()}
	for kind, want := range map[string]bool{
		"change_review":      true,
		"factual_assessment": true,
		"operational_health": false,
		"engineering_result": false,
		"direct_answer":      false,
	} {
		ledger := BuildLedger(changeClaimContract(kind), evidence, coverage, now)
		if got := ledger.Claims["change.recent"].Resolved; got != want {
			t.Errorf("%s: unknown coverage resolved = %v, want %v", kind, got, want)
		}
		correction := ledger.CompletionCorrectionFor("decision_ready", "")
		if want && correction != "" {
			t.Errorf("%s: an answered claim was still corrected: %q", kind, correction)
		}
		if !want && correction == "" {
			t.Errorf("%s: an unanswered claim drew no correction", kind)
		}
	}
}

// Evidence may legally carry dimensions and no observation prose, and a
// contradiction set made only of such records rendered as nothing: a live
// blitz correction on 2026-08-14 read "host.current_state (nomad-hvn01 through
// nomad-hvn05 returned fresh snapshots… — contradicted by: )", which told the
// model to reconcile a contradiction the host never named. There is no reply
// that satisfies that; the episode spent its attempts against an empty clause.
func TestAContradictionWithoutProseStillGetsNamed(t *testing.T) {
	now := time.Date(2026, 8, 14, 19, 55, 0, 0, time.UTC)
	view := ClaimView{
		Requirement: ClaimRequirement{ID: "host.current_state", Layer: "host", Required: true},
		State:       ClaimMixed,
		Evidence: []core.Evidence{{
			Observation: "nomad-hvn01 through nomad-hvn05 returned fresh snapshots.",
			SourceName:  "Emisar five-host load and memory snapshot",
			ObservedAt:  now.Add(-time.Minute),
		}},
		Contradictions: []core.Evidence{{
			// No observation prose — dimensions-only, as ValidateEvidence allows.
			SourceName: "nomad node status",
			Dimensions: map[string]string{"host": "nomad-hvn03", "state": "draining"},
			ObservedAt: now.Add(-2 * time.Minute),
		}},
	}
	detail, nameable := contradictionDetail(view)
	if !nameable {
		t.Fatalf("a dimensions-only conflicting record was judged unnameable: %+v", view)
	}
	if strings.Contains(detail, "contradicted by: )") ||
		strings.HasSuffix(strings.TrimSpace(detail), "contradicted by:") {
		t.Fatalf("the contradiction clause is still empty: %q", detail)
	}
	for _, want := range []string{"host.current_state", "nomad node status", "host=nomad-hvn03"} {
		if !strings.Contains(detail, want) {
			t.Fatalf("contradiction detail %q does not name %q", detail, want)
		}
	}
}
