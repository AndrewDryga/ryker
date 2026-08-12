package decision

import (
	"strings"
	"testing"
	"time"
)

func TestParseWatchDecisionAcceptsSeveralScheduleOffers(t *testing.T) {
	raw := `{
		"action":"reply",
		"operations":[
			{"id":"schedule-tomorrow","type":"offer_schedule","schedule_offer":{"title":"Check Zot logs tomorrow","prompt":"Check Zot logs for the authentication failure fixed in this thread and report the result here.","repository":"tenant-infra","recurrence":"once","start_at":"2026-08-12T09:00:00-06:00","timezone":"America/Merida"}},
			{"id":"schedule-three-days","type":"offer_schedule","schedule_offer":{"title":"Check Zot logs in three days","prompt":"Check Zot logs for the authentication failure fixed in this thread and report the result here.","repository":"tenant-infra","recurrence":"once","start_at":"2026-08-14T09:00:00-06:00","timezone":"America/Merida"}},
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
