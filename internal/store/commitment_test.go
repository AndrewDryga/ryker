package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestAgentRunsProjectDurableOperatorCommitments(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CINFRA", ThreadTS: "1700.001",
		ConversationKey: "channel:CINFRA", SourceKind: "watch", SourceID: "input_1",
		UserID: "UOPERATOR", Repository: "emisar",
		CommitmentTitle: "Check production health",
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %v, %v", run, created, err)
	}
	commitment, err := st.GetCommitmentByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if commitment.Title != "Check production health" ||
		commitment.State != core.CommitmentQueued ||
		commitment.Status != "Accepted" ||
		commitment.NextAction != "Plan the work" {
		t.Fatalf("queued commitment = %+v", commitment)
	}

	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWorking, "investigating", "Investigating",
		"Complete the evidence plan", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	commitment, err = st.GetCommitmentByRun(ctx, run.ID)
	if err != nil || commitment.State != core.CommitmentWorking ||
		commitment.Status != "Investigating" {
		t.Fatalf("working commitment = %+v, %v", commitment, err)
	}

	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeBlocked, "blocked", "provider unavailable",
		"Restore provider access", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	commitment, err = st.GetCommitmentByRun(ctx, run.ID)
	if err != nil || commitment.State != core.CommitmentBlocked ||
		commitment.Status != "provider unavailable" {
		t.Fatalf("blocked commitment = %+v, %v", commitment, err)
	}
	active, err := st.ListActiveCommitments(ctx, 10)
	if err != nil || len(active) != 1 || active[0].AgentRunID != run.ID {
		t.Fatalf("active commitments = %+v, %v", active, err)
	}
	count, err := st.CountActiveCommitments(ctx)
	if err != nil || count != 1 {
		t.Fatalf("active count = %d, %v", count, err)
	}

	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "finished", "Completed", "",
		time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	active, err = st.ListActiveCommitments(ctx, 10)
	if err != nil || len(active) != 0 {
		t.Fatalf("completed commitment remains active = %+v, %v", active, err)
	}
}

// A commitment made by a replacement attempt must stay visible.
//
// This is the bug that motivated keying commitments by episode. They were keyed
// by agent run, and the projection reached the episode through
// work_episodes.agent_run_id — which names the ORIGINATING run. A commitment
// belonging to a replacement attempt joined to nothing and vanished from every
// "what are you working on" view while still sitting in the table.
//
// It is not hypothetical: on the deployed database this was written against,
// 16 of 335 commitments were invisible. The design document lists "no accepted
// commitment disappears without a terminal explanation" as a hard invariant,
// and this violated it silently, which is the worst way to violate one.
func TestResumedEpisodeKeepsItsCommitmentVisible(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CINFRA", ThreadTS: "1700.010",
		ConversationKey: "channel:CINFRA", SourceKind: "watch", SourceID: "input_resume",
		UserID: "UOPERATOR", Repository: "emisar",
		CommitmentTitle: "Verify the rollout",
	})
	if err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}

	before, err := st.ListActiveCommitments(ctx, 20)
	if err != nil || len(before) != 1 {
		t.Fatalf("commitments before the retry = %d, %v", len(before), err)
	}

	// The episode is resumed with a replacement attempt, as it would be after a
	// restart or a provider failure.
	replacement, _, err := st.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CINFRA", ThreadTS: "1700.010",
		ConversationKey: "channel:CINFRA", SourceKind: "watch", SourceID: "input_resume_2",
		UserID: "UOPERATOR", Repository: "emisar",
		CommitmentTitle: "Verify the rollout",
	})
	if err != nil {
		t.Fatalf("queue replacement attempt: %v", err)
	}

	after, err := st.ListActiveCommitments(ctx, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 1 {
		t.Fatalf("commitments after the retry = %d, want exactly 1 — one promise, "+
			"not one per attempt and not zero", len(after))
	}
	if after[0].Title != "Verify the rollout" {
		t.Fatalf("commitment title = %q; the promise as first made must survive", after[0].Title)
	}

	// And it is reachable from the replacement attempt, not only the original.
	found, err := st.GetCommitmentByRun(ctx, replacement.ID)
	if err != nil {
		t.Fatalf("commitment unreachable from the replacement attempt: %v", err)
	}
	if found.Title != "Verify the rollout" {
		t.Fatalf("commitment from replacement = %q", found.Title)
	}
}
