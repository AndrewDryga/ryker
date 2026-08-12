package decision_test

import (
	"testing"
	"time"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/evidencepolicy"
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

func TestEvidenceOperationIDIsCanonicalForCauseReferences(t *testing.T) {
	decision, err := decisionpkg.ParseWatchDecision(`{"action":"reply","operations":[
		{"id":"cause-live","type":"record_evidence","evidence":{"id":"duplicate-payload-id","claim_id":"dependency.current_health","claim":"The dependency is healthy.","observation":"The live probe failed.","relation":"contradicts","health_effect":"unhealthy","source_type":"monitoring","source_name":"probe"}},
		{"id":"change-current","type":"record_evidence","evidence":{"id":"duplicate-payload-id","claim_id":"change.recent","claim":"The revision is current.","observation":"The expected revision is deployed.","relation":"supports","health_effect":"none","source_type":"repository","source_name":"repository"}},
		{"id":"alert","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue","impact":"Requests fail.","cause_status":"identified","cause":"The dependency is unavailable.","cause_claim_ids":["dependency.current_health"],"evidence_refs":["cause-live"],"immediate_action":"Fail over.","verification":"Probe succeeds.","long_term_solution":"Remove the single dependency."}},
		{"id":"complete","type":"complete_episode","completion":{"message":"The dependency is unavailable.","completion":{"status":"decision_ready","summary":"Dependency failure confirmed."}}}
	]}`, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if len(decision.Evidence) != 2 || decision.Evidence[0].ID != "cause-live" ||
		decision.Evidence[1].ID != "change-current" {
		t.Fatalf("canonical evidence ids = %+v", decision.Evidence)
	}
	if correction := evidencepolicy.AlertCauseCorrection(
		decision.AlertAssessment, decision.Evidence,
	); correction != "" {
		t.Fatalf("canonical cause reference rejected: %s", correction)
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

func TestSilentExternalWaitDoesNotReexpandCompletionIntoReply(t *testing.T) {
	response := `{"action":"ignore","operations":[
		{"id":"wait-run","type":"wait_external","external_wait":{
			"id":"wake-run","kind":"terraform_run",
			"event_matcher":{"run_id":"run-abc"},
			"poll_after":"2026-08-10T12:01:00Z"}},
		{"id":"complete","type":"complete_episode","completion":{
			"message":"The run is still planning.",
			"completion":{"status":"decision_ready","verdict":"in_progress","summary":"Still planning."}}}]}`
	decision, err := decisionpkg.ParseWatchDecision(response, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if decision.Action != "ignore" || decision.Message != "" || decision.Completion != nil {
		t.Fatalf("silent wait projected a reply: %+v", decision)
	}
	if len(decision.AppliedOperations) != 1 ||
		decision.AppliedOperations[0].Type != "wait_external" {
		t.Fatalf("silent wait operations = %+v", decision.AppliedOperations)
	}
	if len(decision.Operations) != 1 || decision.Operations[0].Type != "wait_external" {
		t.Fatalf("canonical silent wait operations = %+v", decision.Operations)
	}
}

func TestSilentExternalWaitDoesNotRequireCompletion(t *testing.T) {
	response := `{"action":"ignore","operations":[
		{"id":"evidence-run","type":"record_evidence","evidence":{
			"claim_id":"terraform.run_state","claim":"The run is nonterminal.",
			"observation":"HCP Terraform reports planning.","relation":"supports",
			"health_effect":"none","source_type":"monitoring","source_id":"run-abc",
			"source_name":"HCP Terraform","observed_at":"2026-08-10T12:00:00Z",
			"freshness":"live","confidence":"high"}},
		{"id":"wait-run","type":"wait_external","external_wait":{
			"id":"wake-run","kind":"terraform_run",
			"event_matcher":{"run_id":"run-abc"},
			"poll_after":"2026-08-10T12:01:00Z"}}]}`
	decision, err := decisionpkg.ParseWatchDecision(response, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if decision.Action != "ignore" || decision.Message != "" || decision.Completion != nil {
		t.Fatalf("silent wait projected a reply: %+v", decision)
	}
	if len(decision.AppliedOperations) != 2 ||
		decision.AppliedOperations[1].Type != "wait_external" {
		t.Fatalf("silent wait operations = %+v", decision.AppliedOperations)
	}
}

func TestBlockedExternalWaitBecomesUsefulReply(t *testing.T) {
	response := `{"action":"ignore","operations":[
		{"id":"wait-run","type":"wait_external","external_wait":{
			"id":"wake-run","kind":"terraform_run",
			"event_matcher":{"run_id":"run-abc"},
			"poll_after":"2026-08-10T12:01:00Z"}},
		{"id":"complete","type":"complete_episode","completion":{
			"message":"The plan is ready, but its complete drift list is unavailable.",
			"completion":{"status":"blocked","summary":"Plan review is incomplete.",
				"material_gaps":["Three drifted resources are omitted."],
				"blocker_kind":"source_unavailable",
				"attempts":["Read the exact saved plan."],
				"next_action":"Expose the complete drift list."}}}]}]}`
	decision, err := decisionpkg.ParseWatchDecision(response, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if decision.Action != "reply" ||
		decision.Message != "The plan is ready, but its complete drift list is unavailable." ||
		decision.Completion == nil || decision.Completion.Status != "blocked" {
		t.Fatalf("blocked wait decision = %+v", decision)
	}
	if len(decision.AppliedOperations) != 2 ||
		decision.AppliedOperations[0].Type != "wait_external" {
		t.Fatalf("blocked wait operations = %+v", decision.AppliedOperations)
	}
}
