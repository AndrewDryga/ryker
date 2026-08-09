package decision_test

import (
	"testing"
	"time"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// Both of these are the exact shapes a real model returned on the promoted
// regression corpus on 2026-08-09. Each was thrown away whole — the reply, the
// memory, the feedback and the offers with it — over a field name. The answers
// were right; only the spelling was not, and a retry costs a full turn.
func TestRecordedFieldNameDriftStillDecodes(t *testing.T) {
	for _, testCase := range []struct {
		name     string
		response string
	}{
		{
			// json: unknown field "topic" — memory_offer.subject.
			name: "memory offer names the subject a topic",
			response: `{"action":"reply",
				"attention":{"addressee":"responder","urgency":0,"confidence":3,"novelty":2,"ownership":2},
				"reason":"The operator set lasting guidance for future reviews.",
				"operations":[
					{"id":"offer-health-guidance","type":"offer_memory","memory_offer":{
						"topic":"Whole-platform health review baseline",
						"value":"Prefer the published runbook whole-platform-health-review-v5@3.",
						"scope":"workspace","visibility":"operator"}},
					{"id":"complete","type":"complete_episode","completion":{
						"message":"I'll prefer that runbook, with a published read-only equivalent as the fallback.",
						"completion":{"status":"decision_ready","summary":"Recorded the preferred baseline."}}}]}`,
		},
		{
			// json: unknown field "preference", then "channel_id" behind it.
			name: "offers use the payload names the operation list implied",
			response: `{"action":"reply",
				"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":3,"ownership":3},
				"reason":"The operator gave actionable feedback and asked for durable behavior.",
				"operations":[
					{"id":"feedback-1","type":"record_feedback","feedback":{
						"category":"correctness","sentiment":"negative",
						"summary":"Reply to Terraform notifications in their threads.","needs_followup":false}},
					{"id":"preference-1","type":"offer_preference","preference":{
						"name":"response_location","value":"prefer_thread","scope":"channel"}},
					{"id":"rule-1","type":"offer_rule","rule":{
						"trigger":"terraform_plan","action":"review_terraform_plan","source_kind":"any",
						"scope":"channel","channel_id":"CEVALUATION","repository":"emisar"}},
					{"id":"complete-1","type":"complete_episode","completion":{
						"message":"You're right. The confirmations below propose thread-first replies and plan reviews.",
						"completion":{"status":"decision_ready","summary":"Recorded the feedback and proposed the behavior."}}}]}`,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			decision, err := decisionpkg.ParseWatchDecision(testCase.response, time.Now().UTC())
			if err != nil {
				t.Fatalf("recorded response rejected: %v", err)
			}
			if decision.Action != "reply" || decision.Message == "" {
				t.Fatalf("decision = %+v", decision)
			}
		})
	}
}

// The tolerance is for names of fields that exist. A field that names nothing
// is usually a claim nobody made, and accepting it would report work that was
// never done.
func TestInventedOperationFieldsAreStillRejected(t *testing.T) {
	_, err := decisionpkg.ParseWatchDecision(`{"action":"reply","operations":[
		{"id":"x-1","type":"offer_preference","preference":{"name":"n","value":"v","scope":"channel"},
		 "invented_authority":"granted"},
		{"id":"complete-1","type":"complete_episode","completion":{"message":"hello",
		 "completion":{"status":"decision_ready","summary":"done"}}}]}`, time.Now().UTC())
	if err == nil {
		t.Fatal("an invented operation field was accepted")
	}
}
