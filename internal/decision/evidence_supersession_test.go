package decision

import (
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

// The validator stopped rejecting a record that names itself in supersedes —
// re-emitting an id already replaces the older record, so the self-entry is
// redundant, and on 2026-08-15 eight blitz episodes each paid a correction
// round for saying it. Redundant is still not worth storing: a persisted
// self-reference reads as a retirement in every correction that quotes the
// record, and the ledger would skip it on every read forever. Sanitize drops
// the self-entry and keeps the real ones.
func TestSanitizeDropsASelfSupersessionAndKeepsTheRealOnes(t *testing.T) {
	evidence := SanitizeEvidence([]core.Evidence{{
		ID: "evidence-host", ClaimID: "host.current_state",
		Observation: "The host recovered after the restart.",
		SourceType:  "emisar", SourceName: "Emisar",
		Supersedes: []string{"evidence-host", "evidence-host-stale"},
	}}, "", "C1", "slack_1", time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC))
	if len(evidence) != 1 {
		t.Fatalf("evidence = %+v, want the record kept", evidence)
	}
	if got := evidence[0].Supersedes; len(got) != 1 || got[0] != "evidence-host-stale" {
		t.Fatalf("supersedes = %v, want only the real retirement kept", got)
	}
}
