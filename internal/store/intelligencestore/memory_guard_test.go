package intelligencestore_test

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/intelligencestore"
	"github.com/AndrewDryga/responder/internal/store/storetest"
)

// An empty memory update must not erase the channel's situation.
//
// Every ignore decision marshals its memory as '{}', and the channel-memory
// write took that overwrite unconditionally while the conversation-memory
// upsert beside it always guarded against it. Result in production: all four
// channel_memories rows read '{}' — the most recent turn in each channel was a
// quiet one — while the summaries they once held sat intact one table away,
// and every surface introduced every channel as "no current summary".
func TestQuietDecisionDoesNotEraseTheChannelSituation(t *testing.T) {
	ctx := context.Background()
	repo := intelligencestore.New(storetest.DB(t), time.Now)

	if err := repo.BindChannelSession(
		ctx, "COPS", "repo", "ses_1", 1, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}

	if _, err := repo.ApplyWatchDecision(ctx, core.EvaluationDecision{
		ChannelID: "COPS", MessageTS: "1700.001", Repository: "repo",
		SourceInput: "in_1", Mode: "live", Action: "reply",
	}, "investigation", 2,
		core.AgentMemory{SituationSummary: "Rollout verified; drift backlog open."},
	); err != nil {
		t.Fatal(err)
	}

	// The quiet turn: action taken, nothing learned, memory empty.
	if _, err := repo.ApplyWatchDecision(ctx, core.EvaluationDecision{
		ChannelID: "COPS", MessageTS: "1700.002", Repository: "repo",
		SourceInput: "in_2", Mode: "live", Action: "ignore",
	}, "investigation", 3, core.AgentMemory{}); err != nil {
		t.Fatal(err)
	}

	memory, err := repo.GetChannelMemory(ctx, "COPS")
	if err != nil {
		t.Fatal(err)
	}
	if memory.State.SituationSummary != "Rollout verified; drift backlog open." {
		t.Fatalf("a quiet decision erased the channel situation: %+v", memory.State)
	}
}
