package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

// A run whose episode a newer attempt already closed cannot be replayed —
// reopening the episode for it is refused, correctly — and it must not be
// left running either. blitz run_e3cec200 was interrupted by a Coop restart
// at 00:23Z on 2026-08-15 while its starved sibling leased past it and
// completed the episode; every poll after that tried to requeue it, was told
// "terminal episode's latest attempt is run_b7e4a0f, not run_e3cec200", and
// left it running for the next six hours. The refusal is the answer: the run
// is history and says so.
func TestAReplayRefusedByAClosedEpisodeSupersedesTheRunInsteadOfLoopingOnIt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	older, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_older",
	})
	if err != nil {
		t.Fatal(err)
	}
	// The older attempt is mid-flight when a newer attempt on the same
	// episode is queued and finishes the work.
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != older.ID {
		t.Fatalf("leased %s, want the older run %s", leased.ID, older.ID)
	}
	if err := st.BindAgentRunSession(ctx, older.ID, "session_1", 1, "repo", 0, []byte("{}")); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, older.ID, "turn_older", 1, 0); err != nil {
		t.Fatal(err)
	}
	newer, created, err := st.QueueEpisodeAttempt(ctx, older.EpisodeID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_newer",
	})
	if err != nil || !created {
		t.Fatalf("queue newer attempt = %v, %v", created, err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, newer.ID, core.EpisodeCompleted, "finished", "Done", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}

	// Coop restarted under the older run's turn; the poll stages the
	// interruption and asks for a replay.
	if err := st.RequeueAgentRun(
		ctx, older.ID, "Coop restarted under the turn; replaying it in a fresh session",
		0, time.Now().UTC(), true,
	); err != nil {
		t.Fatalf("a replay refused by a closed episode surfaced as an error the poll retries forever: %v", err)
	}
	stored, err := st.GetAgentRun(ctx, older.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunSuperseded {
		t.Fatalf("the older run is %q, want superseded now that a newer attempt closed its episode (last error %q)",
			stored.State, stored.LastError)
	}
}
