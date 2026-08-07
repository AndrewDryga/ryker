package service

import (
	"testing"
	"time"
)

// The audit is about to be used as evidence for deleting a compatibility path,
// so it has to be right about which parser a result used. Replaying an
// engineering task result through the watch parser reports a parse failure that
// says nothing about the legacy path — and an audit that miscounts is worse
// than no audit, because it looks like evidence.
func TestAuditUsesTheParserEachModeActuallyUsed(t *testing.T) {
	now := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	typedWatch := `{"action":"reply","reason":"checked","operations":[` +
		`{"id":"op-1","type":"record_evidence","evidence":{"claim_id":"service.health","claim":"checkout is up",` +
		`"observation":"all pods ready","source_type":"emisar","source_name":"prod-eu"}},` +
		`{"id":"op-2","type":"complete_episode","completion":{"message":"checkout is healthy",` +
		`"completion":{"status":"decision_ready","summary":"checkout is healthy",` +
		`"verdict":"healthy"}}}]}`

	audit := AuditResultProtocol([]StoredResult{
		{RunID: "run_triage", Mode: "triage", Message: typedWatch},
	}, now)
	if audit.Unparsed != 0 {
		t.Fatalf("a typed watch decision was reported unparsed: %v", audit.UnparsedReasons)
	}

	// The same message replayed as an engineering task must not silently count
	// as a watch decision.
	crossed := AuditResultProtocol([]StoredResult{
		{RunID: "run_task", Mode: "engineering_task", Message: typedWatch},
	}, now)
	if crossed.Total != 1 {
		t.Fatalf("total = %d", crossed.Total)
	}
}

// A fallback must be counted and attributed. If the audit reported zero
// because it never looked, it would read as evidence of safety.
func TestAuditCountsAndAttributesFallbacks(t *testing.T) {
	now := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	audit := AuditResultProtocol([]StoredResult{
		{RunID: "a", Mode: "triage", Message: "not json at all"},
	}, now)
	if audit.Unparsed != 1 || len(audit.UnparsedExamples) != 1 {
		t.Fatalf("unparsed = %d, examples = %v", audit.Unparsed, audit.UnparsedExamples)
	}
	if audit.UnparsedExamples[0] != "a" {
		t.Fatalf("example = %q, want the run id so it can be looked up", audit.UnparsedExamples[0])
	}
	if len(audit.UnparsedReasons) != 1 || audit.UnparsedReasons[0] == "" {
		t.Fatal("an unparsed result must carry why it could not be read")
	}
}

// An empty window must not read as a clean bill of health.
func TestAuditOfNothingConcludesNothing(t *testing.T) {
	audit := AuditResultProtocol(nil, time.Now())
	if audit.Total != 0 || audit.Fallback != 0 || audit.Typed != 0 {
		t.Fatalf("audit of an empty corpus = %+v", audit)
	}
}
