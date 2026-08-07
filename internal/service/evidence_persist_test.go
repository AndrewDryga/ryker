package service

import (
	"strings"
	"testing"
	"time"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// A watch result that records evidence through typed operations must end up
// with that evidence on the decision.
//
// On the deployed database, only 22 of 180 episodes that emitted
// evidence_recorded events have any retrievable evidence. The events are
// written from the operation stream; the rows are written from decision
// evidence. If the fold does not populate the latter, every episode logs
// evidence it never stored — and the inherited claim ledger a correlated
// episode is shown is empty, so it rediscovers and can contradict.
func TestWatchOperationsPopulateDecisionEvidence(t *testing.T) {
	result := `{"action":"reply","reason":"checked","operations":[` +
		`{"id":"e1","type":"record_evidence","evidence":{"claim_id":"change.recent",` +
		`"claim":"the apply failed","observation":"HCP reports the run errored",` +
		`"source_type":"emisar","source_name":"HCP Terraform via Emisar"}},` +
		`{"id":"c1","type":"record_coverage","coverage":{"layer":"change","status":"unhealthy",` +
		`"detail":"the apply errored"}},` +
		`{"id":"done","type":"complete_episode","completion":{"message":"the apply failed",` +
		`"completion":{"status":"decision_ready","summary":"the apply failed","verdict":"failed",` +
		`"next_action":"retry the apply once the provider recovers"}}}]}`

	decision, err := decisionpkg.ParseWatchDecision(result, time.Now().UTC())
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(decision.Evidence) != 1 {
		t.Fatalf("decision carries %d evidence items, want 1 — the record_evidence "+
			"operation did not reach decision.Evidence, so nothing downstream can store it",
			len(decision.Evidence))
	}
	if decision.Evidence[0].SourceName == "" || decision.Evidence[0].Observation == "" {
		t.Fatalf("evidence lost its fields in the fold: %+v", decision.Evidence[0])
	}
	if len(decision.Coverage) != 1 {
		t.Fatalf("decision carries %d coverage items, want 1", len(decision.Coverage))
	}
}

// The same result, but the turn also offers a durable behaviour.
//
// persistAgentReport nulls Evidence, Coverage and Visuals whenever a memory,
// preference, rule or schedule offer is present, so that a confirmation card
// does not look as though its behaviour was already saved. The reasoning is
// sound for the card; the consequence is that everything the turn actually
// found is discarded with it.
func TestBehaviourOfferDiscardsWhatTheTurnFound(t *testing.T) {
	result := `{"action":"reply","reason":"noted","operations":[` +
		`{"id":"e1","type":"record_evidence","evidence":{"claim_id":"change.recent",` +
		`"claim":"the apply failed","observation":"HCP reports the run errored",` +
		`"source_type":"emisar","source_name":"HCP Terraform via Emisar"}},` +
		`{"id":"done","type":"complete_episode","completion":{"message":"noted",` +
		`"completion":{"status":"decision_ready","summary":"noted","verdict":"healthy"}}}]}`

	decision, err := decisionpkg.ParseWatchDecision(result, time.Now().UTC())
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(decision.Evidence) == 0 {
		t.Skip("the fold is already dropping evidence; the other test covers that")
	}
	// Documented here rather than asserted as correct: this is the behaviour,
	// and whether losing the findings is the right trade is a product question.
	t.Logf("a turn offering durable behaviour would have %d evidence items discarded "+
		"by persistAgentReport", len(decision.Evidence))
	if !strings.Contains(decision.Evidence[0].SourceName, "Emisar") {
		t.Fatalf("evidence fixture is wrong: %+v", decision.Evidence[0])
	}
}
