package service

import (
	"encoding/json"
	"testing"
	"time"
)

// A result Responder cannot read must go back to the model, not to the person
// waiting on it.
//
// The watch path has always corrected and retried here. Incident and
// engineering-task runs did not: one malformed response ended the turn and put
// a parse error in Slack. Someone asking about an outage cannot act on
// `json: unknown field`, and the model never learned it had done anything wrong.
//
// This pins the budget arithmetic that decides when a person finally has to be
// told — the part that is easy to get off by one and impossible to notice,
// because being wrong in one direction means retrying forever and in the other
// means never retrying at all.
func TestMalformedReportCorrectionBudget(t *testing.T) {
	const maximum = 3

	for _, testCase := range []struct {
		name      string
		corrected int
		terminal  bool
	}{
		{"the first failure is corrected, not reported", 1, false},
		{"and the second", 2, false},
		{"the last one in the budget stops", 3, true},
		{"and anything past it stays stopped", 4, true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if got := terminalStructuredCorrection(testCase.corrected, 1, maximum); got != testCase.terminal {
				t.Fatalf("terminal after %d corrections = %t, want %t",
					testCase.corrected, got, testCase.terminal)
			}
		})
	}

	// A budget of zero or less must not mean "retry forever". A misconfigured
	// limit that loops is worse than one that gives up immediately, because it
	// burns the model budget on a turn nobody is waiting for any more.
	if !terminalStructuredCorrection(1, 1, 0) {
		t.Fatal("a zero correction budget allowed a retry")
	}

	// The second budget, which the first cannot see: the corrections the whole
	// EPISODE has spent. A re-triggered alert opens a new run with a fresh
	// within-run count, so that number is 1 again however many rounds the
	// episode has already burned. One episode took twenty-one runs and a hundred
	// and thirty corrections before anyone noticed, and it needed an operator
	// from about the second hour.
	//
	// It counts corrections rather than the episode's attempt number, which were
	// the same measurement only while every re-triggered alert opened its own
	// episode. See TestALongLivedStreamEpisodeKeepsItsCorrectionBudget.
	if terminalStructuredCorrection(1, maximum, maximum) {
		t.Fatal("an episode inside its correction budget was refused its next correction")
	}
	if !terminalStructuredCorrection(1, maximum+1, maximum) {
		t.Fatal("a fresh run on an exhausted episode bought itself a whole new budget")
	}
}

// The correction counter has to survive the requeue, or every attempt looks
// like the first and the run retries until its transport budget runs out.
func TestCorrectionCountSurvivesTheContextRoundTrip(t *testing.T) {
	assembled := assembledAgentContext{
		Repository:                    "emisar",
		InitialTaskChangesFingerprint: "sha-before-the-turn",
		StructuredCorrections:         2,
		CapturedAt:                    time.Now().UTC(),
	}
	encoded, err := json.Marshal(assembled)
	if err != nil {
		t.Fatal(err)
	}
	decoded, ok := decodeAssembledAgentContext(encoded)
	if !ok {
		t.Fatal("the assembled context did not decode")
	}
	if decoded.StructuredCorrections != 2 {
		t.Fatalf("corrections after round trip = %d, want 2 — the counter is not persisted, "+
			"so every retry would look like the first", decoded.StructuredCorrections)
	}
	if decoded.Repository != "emisar" {
		t.Fatalf("round trip lost the repository: %+v", decoded)
	}
	if decoded.InitialTaskChangesFingerprint != "sha-before-the-turn" {
		t.Fatalf("round trip lost the task fingerprint: %+v", decoded)
	}
}

// An undecodable context must not be replaced by a fresh one.
//
// Recording the correction means writing the context back. If the decode
// failed, what gets written is a zero value — losing the repository, the
// captured situations, and the fingerprint the publication staleness check
// compares against. Stopping and telling the operator is the lesser harm.
func TestUndecodableContextIsNotOverwrittenByACorrection(t *testing.T) {
	for _, broken := range [][]byte{nil, []byte("{}"), []byte("not json"),
		[]byte(`{"repository":"emisar"}`)} {
		if _, ok := decodeAssembledAgentContext(broken); ok {
			t.Fatalf("%q decoded; this test no longer covers the case it means to", broken)
		}
	}
}

// The table that used to live here checked which terminal triage failures were
// worth telling a channel about. Nothing is: every one of them now pauses the
// message and ends with a bounded failure notice, so there is no decision left to test.
