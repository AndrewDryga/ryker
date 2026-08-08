package decision

import (
	"strings"
	"testing"
	"time"
)

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
