package store

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// Replaying a source after its run has already been attached to an existing
// episode must preserve that durable identity. The generic input recovery path
// does not carry an Episode value, and used to synthesize a second episode for
// the idempotent run while moving agent_runs.episode_id away from its attempt.
func TestIdempotentAgentRunQueuePreservesStoredEpisode(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	original, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1.0",
		ConversationKey: "thread:COPS:1.0", SourceKind: "watch", SourceID: "original",
		Repository: "repo", Prompt: "Check the rollout",
	})
	if err != nil || !created {
		t.Fatalf("queue original run = %+v, %t, %v", original, created, err)
	}
	resumed, created, err := st.QueueEpisodeAttempt(ctx, original.EpisodeID, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1.0",
		ConversationKey: "thread:COPS:1.0", SourceKind: "watch", SourceID: "wake-up",
		Repository: "repo", Prompt: "Resume the rollout check",
	})
	if err != nil || !created {
		t.Fatalf("queue resumed run = %+v, %t, %v", resumed, created, err)
	}

	replayed, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ThreadTS: "1.0",
		ConversationKey: "thread:COPS:1.0", SourceKind: "watch", SourceID: "wake-up",
		Repository: "repo", Prompt: "Resume the rollout check",
	})
	if err != nil || created {
		t.Fatalf("replay resumed run = %+v, %t, %v", replayed, created, err)
	}
	if replayed.ID != resumed.ID || replayed.EpisodeID != original.EpisodeID {
		t.Fatalf("replay changed episode: replayed = %+v, resumed = %+v", replayed, resumed)
	}
	attempt, err := st.GetEpisodeAttempt(ctx, resumed.AttemptID)
	if err != nil {
		t.Fatal(err)
	}
	if attempt.EpisodeID != replayed.EpisodeID {
		t.Fatalf("run episode %q split from attempt episode %q", replayed.EpisodeID, attempt.EpisodeID)
	}
}
