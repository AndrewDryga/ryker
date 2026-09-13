package decision

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/investigation"
)

func TestParseWatchDecisionAcceptsSeveralScheduleOffers(t *testing.T) {
	raw := `{
		"action":"reply",
		"operations":[
			{"id":"schedule-tomorrow","type":"offer_schedule","schedule_offer":{"title":"Check Zot logs tomorrow","prompt":"Check Zot logs for the authentication failure fixed in this thread and report the result here.","repository":"blitz-infra","recurrence":"once","start_at":"2026-08-12T09:00:00-06:00","timezone":"America/Merida"}},
			{"id":"schedule-three-days","type":"offer_schedule","schedule_offer":{"title":"Check Zot logs in three days","prompt":"Check Zot logs for the authentication failure fixed in this thread and report the result here.","repository":"blitz-infra","recurrence":"once","start_at":"2026-08-14T09:00:00-06:00","timezone":"America/Merida"}},
			{"id":"complete","type":"complete_episode","completion":{"message":"I can schedule both checks together."}}
		]
	}`

	parsed, err := ParseWatchDecision(raw, time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("parse two schedule offers: %v", err)
	}
	if parsed.ScheduleOffer == nil || len(parsed.ScheduleOffers) != 1 {
		t.Fatalf("schedule offers were not preserved: primary=%+v additional=%+v", parsed.ScheduleOffer, parsed.ScheduleOffers)
	}
	if parsed.ScheduleOffer.Title != "Check Zot logs tomorrow" || parsed.ScheduleOffers[0].Title != "Check Zot logs in three days" {
		t.Fatalf("schedule offers changed order: primary=%+v additional=%+v", parsed.ScheduleOffer, parsed.ScheduleOffers)
	}
}

func TestValidateAttentionAssessmentRequiresConcreteMaterialContribution(t *testing.T) {
	valid := AttentionAssessment{
		Addressee: "channel", Urgency: 1, Confidence: 3, Novelty: 2, Ownership: 2,
		Contribution: "new_evidence", Material: true,
	}
	if err := ValidateAttentionAssessment(valid); err != nil {
		t.Fatalf("valid attention assessment: %v", err)
	}

	for name, assessment := range map[string]AttentionAssessment{
		"material without contribution": {
			Addressee: "channel", Contribution: "none", Material: true,
		},
		"unknown contribution": {
			Addressee: "channel", Contribution: "summary", Material: true,
		},
	} {
		t.Run(name, func(t *testing.T) {
			if err := ValidateAttentionAssessment(assessment); err == nil {
				t.Fatalf("assessment was accepted: %+v", assessment)
			}
		})
	}

}

// A reply that is both fenced and schema-invalid must be reported for the
// schema, not the fence.
//
// Claude fences JSON readily, and the recovery already extracts the object
// cleanly — but the error it reported came from decoding the raw text around
// it, so an invented field surfaced as "invalid character '`'". That is the
// message the malformed-report correction retry hands back to the model, so
// the model was being asked to fix punctuation it had not got wrong while the
// real fault went unnamed. Observed on a live episode replay, 2026-08-08.
func TestParseWatchDecisionReportsTheSchemaFaultNotTheFence(t *testing.T) {
	fenced := "```json\n{\n  \"action\": \"reply\",\n  \"message\": \"hello\",\n  \"claim_note\": null\n}\n```"
	_, err := ParseWatchDecision(fenced, time.Now().UTC())
	if err == nil {
		t.Fatal("an invented field was accepted")
	}
	if !strings.Contains(err.Error(), "claim_note") {
		t.Fatalf("error does not name the invented field: %v", err)
	}

	// A fenced reply that is otherwise valid still parses: the fence itself was
	// never the problem.
	good := "```json\n{\"action\":\"reply\",\"message\":\"hello\"}\n```"
	parsed, err := ParseWatchDecision(good, time.Now().UTC())
	if err != nil || parsed.Action != "reply" {
		t.Fatalf("fenced valid reply = %+v, %v", parsed, err)
	}
}

// Every refusal the claim ledger writes must survive this predicate, because
// StructuredResultFailure is the only thing that puts a correction back in
// front of the model. A ledger correction it does not recognise makes
// agentprompt.Continuation return the empty string, and the model is re-asked
// with no idea what was wrong — 79445e8's comment records that happening once
// already, on the incident and engineering-task path.
//
// The coverage arm is the one added on 2026-08-15. A claim whose every
// recorded statement supports it was being refused with the contradiction
// text, which names moves that do not exist when nothing disagrees; splitting
// it into its own sentence would have silently dropped it here.
func TestEveryClaimLedgerRefusalSurvivesIntoTheRetryPrompt(t *testing.T) {
	now := time.Date(2026, 8, 15, 6, 42, 0, 0, time.UTC)
	contract := investigation.InvestigationContract{
		Claims: []investigation.ClaimRequirement{{
			ID: "change.recent", Layer: "change", Required: true,
		}},
		Completion: investigation.CompletionRule{ConclusionKind: "operational_health"},
	}
	supporting := core.Evidence{
		ID: "evidence-topology", ClaimID: "change.recent", Relation: "supports",
		Observation: "the live backend matches the declared topology",
		SourceType:  "repository", SourceName: "Emisar infra configuration",
		ObservedAt: now, Confidence: "high",
	}
	conflicting := core.Evidence{
		ID: "evidence-drift", ClaimID: "change.recent", Relation: "contradicts",
		Observation: "the running revision is not the declared one",
		SourceType:  "emisar", SourceName: "Nomad allocation events",
		ObservedAt: now, Confidence: "high",
	}
	unknownCoverage := []core.Coverage{{
		Layer: "change", ClaimIDs: []string{"change.recent"}, Status: "unknown",
		Detail: "the exact deployed commit remains unknown", ObservedAt: now,
	}}

	for name, refusal := range map[string]string{
		"supported but not established by coverage": investigation.BuildLedger(
			contract, []core.Evidence{supporting}, unknownCoverage, now,
		).CompletionCorrectionFor("decision_ready", "healthy"),
		"contradicted": investigation.BuildLedger(
			contract, []core.Evidence{supporting, conflicting}, unknownCoverage, now,
		).CompletionCorrectionFor("decision_ready", "healthy"),
		"no fresh supporting evidence": investigation.BuildLedger(
			contract, nil, unknownCoverage, now,
		).CompletionCorrectionFor("decision_ready", "healthy"),
	} {
		if refusal == "" {
			t.Fatalf("the %s ledger no longer refuses, so this test proves nothing", name)
		}
		if !ClaimsCorrection(refusal) {
			t.Fatalf(
				"the %s refusal is not recognised as a claims correction, so the retry "+
					"prompt drops it and the model is re-asked blind:\n%s",
				name, refusal,
			)
		}
	}
}
