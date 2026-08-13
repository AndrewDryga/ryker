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

// A channel does not have a goal.
//
// Channel memory and thread memory are the same shape under two keys, so a
// turn answered in the channel wrote its own working state as the channel's.
// On an alerts feed that is plainly wrong: #backend-ops carried one
// investigation's objective — "Explain why website image bumps are not
// reaching VA1" — as though the room existed to answer it, when it exists to
// carry alerts for many services and that goal belonged to one thread.
//
// Everything that describes the place survives. Only the objective is dropped,
// and only when there is no thread to own it.
func TestChannelMemoryKeepsThePlaceAndDropsTheTaskGoal(t *testing.T) {
	ctx := context.Background()
	repo := intelligencestore.New(storetest.DB(t), time.Now)
	if err := repo.BindChannelSession(
		ctx, "COPS", "repo", "ses_1", 1, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	state := core.AgentMemory{
		Goal:             "Explain why website image bumps are not reaching VA1.",
		ChannelPurpose:   "Shared infrastructure operations feed.",
		SituationSummary: "Web deploys were reported not applying.",
		Topology:         []string{"va1-apps maps to terraform/environments/va1/apps."},
		Decisions:        []string{"Judge web deploys by the va1-apps workspace."},
	}

	// In the channel itself: no thread owns the objective.
	if _, err := repo.ApplyWatchDecision(ctx, core.EvaluationDecision{
		ChannelID: "COPS", MessageTS: "1700.001", Repository: "repo",
		SourceInput: "in_1", Mode: "live", Action: "reply",
	}, "investigation", 2, state); err != nil {
		t.Fatal(err)
	}
	channel, err := repo.GetConversationMemory(ctx, "COPS", "")
	if err != nil {
		t.Fatal(err)
	}
	if channel.State.Goal != "" {
		t.Fatalf("the channel kept a thread's goal: %q", channel.State.Goal)
	}
	if channel.State.ChannelPurpose != "Shared infrastructure operations feed." ||
		len(channel.State.Topology) != 1 || len(channel.State.Decisions) != 1 ||
		channel.State.SituationSummary == "" {
		t.Fatalf("dropping the goal took the channel's own knowledge with it: %+v", channel.State)
	}

	// In a thread, the goal is exactly what the memory is for.
	if _, err := repo.ApplyWatchDecision(ctx, core.EvaluationDecision{
		ChannelID: "COPS", ThreadTS: "1700.001", MessageTS: "1700.002",
		Repository: "repo", SourceInput: "in_2", Mode: "live", Action: "reply",
	}, "investigation", 3, state); err != nil {
		t.Fatal(err)
	}
	thread, err := repo.GetConversationMemory(ctx, "COPS", "1700.001")
	if err != nil {
		t.Fatal(err)
	}
	if thread.State.Goal != state.Goal {
		t.Fatalf("a thread lost the goal it was pursuing: %q", thread.State.Goal)
	}
}
