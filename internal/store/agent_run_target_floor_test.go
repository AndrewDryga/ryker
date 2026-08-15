package store

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// The escalation bookkeeping edits the envelope it finds, not the one the
// caller was holding.
//
// This is the whole reason these two writes live in SQL rather than in a
// decode-modify-encode beside the correction. Both context envelopes are
// re-encoded from typed structs by the paths that write them, and the
// correction paths write the round counter and THEN requeue — so an escalation
// that re-encoded the caller's in-memory copy would drop that increment and
// turn a bounded correction loop into an endless one, which is the exact bug
// the counter was moved off failure_count to prevent. A run's envelope also
// carries fields these methods have never heard of, and losing the repository
// or the captured situations to a rung would be a far worse trade than the
// rung is worth.
func TestALadderFloorEditsTheEnvelopeItFindsAndKeepsTheRest(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_floor",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetAgentRunContext(ctx, queued.ID, []byte(
		`{"repository":"repo","structured_corrections":2,"lane":"investigation"}`,
	)); err != nil {
		t.Fatal(err)
	}

	for round, want := range []int{1, 2, 3} {
		repeats, err := st.NoteAgentRunCorrectionClass(ctx, queued.ID, "incomplete")
		if err != nil {
			t.Fatal(err)
		}
		if repeats != want {
			t.Fatalf("round %d counted %d repeats, want %d", round+1, repeats, want)
		}
	}
	// A different class counts separately: a run that failed two different ways
	// has learned something between rounds, and only the same failure twice is
	// the signal that the rung is the problem.
	if repeats, err := st.NoteAgentRunCorrectionClass(ctx, queued.ID, "unreadable"); err != nil {
		t.Fatal(err)
	} else if repeats != 1 {
		t.Fatalf("a first correction of a second class counted %d repeats, want 1", repeats)
	}
	if err := st.SetAgentRunTargetFloor(ctx, queued.ID, 2); err != nil {
		t.Fatal(err)
	}

	fields := envelopeOf(t, st, queued.ID)
	if string(fields["repository"]) != `"repo"` ||
		string(fields["lane"]) != `"investigation"` ||
		string(fields["structured_corrections"]) != "2" {
		t.Fatalf("the run's own context was overwritten by its bookkeeping: %v", fields)
	}
	if string(fields["correction_classes"]) != `{"incomplete":3,"unreadable":1}` {
		t.Fatalf("correction classes = %s", fields["correction_classes"])
	}
	if string(fields["min_target_index"]) != "2" {
		t.Fatalf("target floor = %s, want 2", fields["min_target_index"])
	}

	// Zero removes the key rather than writing a zero, so a run Coop refused an
	// escalation for is byte-identical to one that never asked.
	if err := st.SetAgentRunTargetFloor(ctx, queued.ID, 0); err != nil {
		t.Fatal(err)
	}
	if _, present := envelopeOf(t, st, queued.ID)["min_target_index"]; present {
		t.Fatal("a cleared floor left its key behind")
	}
}

func envelopeOf(t *testing.T, st *Store, id string) map[string]json.RawMessage {
	t.Helper()
	run, err := st.GetAgentRun(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	fields := map[string]json.RawMessage{}
	if err := json.Unmarshal(run.Context, &fields); err != nil {
		t.Fatal(err)
	}
	return fields
}
