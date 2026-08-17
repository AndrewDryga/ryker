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
	if err := st.SetAgentRunTargetFloor(ctx, queued.ID, 2, 0); err != nil {
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
	if err := st.SetAgentRunTargetFloor(ctx, queued.ID, 0, 0); err != nil {
		t.Fatal(err)
	}
	if _, present := envelopeOf(t, st, queued.ID)["min_target_index"]; present {
		t.Fatal("a cleared floor left its key behind")
	}
}

// The remembered ceiling is the LOWEST rung Coop has ever refused.
//
// Rungs 10, 11 and 12 asked for and refused on 2026-08-16 while a thirteen-round
// correction loop ran, in that order — so a record that kept the latest refusal
// would end up holding 12 and let the host go on asking for 10 and 11 forever.
// The ladder does not grow during a run, and the lowest refusal is the only
// bound that holds against every later one.
func TestTheLowestRefusedRungIsTheOneRemembered(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_refused",
	})
	if err != nil {
		t.Fatal(err)
	}
	// Refused in the order the production run met them, lowest first, then two
	// higher rungs computed from the same climbing repeat count.
	for _, refused := range []int{10, 11, 12} {
		if err := st.SetAgentRunTargetFloor(ctx, queued.ID, 0, refused); err != nil {
			t.Fatal(err)
		}
	}
	if got := string(envelopeOf(t, st, queued.ID)["refused_target_floor"]); got != "10" {
		t.Fatalf("remembered refused rung = %s, want the lowest one refused, 10", got)
	}
	// A raise that refuses nothing leaves the ceiling alone: the two halves of
	// the ladder record are written by different paths on different rounds.
	if err := st.SetAgentRunTargetFloor(ctx, queued.ID, 4, 0); err != nil {
		t.Fatal(err)
	}
	fields := envelopeOf(t, st, queued.ID)
	if string(fields["refused_target_floor"]) != "10" ||
		string(fields["min_target_index"]) != "4" {
		t.Fatalf("a raise rewrote the ladder ceiling: %v", fields)
	}
}

// Accepting the degraded turn consumes only the one-shot routing permission.
// The desired rung is history about why the run escalated and must survive so
// a later healthy turn still prefers that rung.
func TestASuccessfulSubmissionConsumesOnlyTheDegradedFallback(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_fallback",
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	contextJSON := []byte(
		`{"min_target_index":1,"degraded_target_fallback_pending":true}`,
	)
	if err := st.BindAgentRunSession(
		ctx, leased.ID, "session_codex_claude", 1, "repo", 0, contextJSON,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, leased.ID, "turn_codex", 2, 0); err != nil {
		t.Fatal(err)
	}

	fields := envelopeOf(t, st, queued.ID)
	if string(fields["min_target_index"]) != "1" {
		t.Fatalf("successful degraded submission erased desired floor: %v", fields)
	}
	if _, pending := fields["degraded_target_fallback_pending"]; pending {
		t.Fatalf("successful degraded submission left its one-shot fallback armed: %v", fields)
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
