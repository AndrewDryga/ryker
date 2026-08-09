package webui

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// Search reaches both places an operator remembers work by — the commitment
// title and the episode's own status line — and the count and the list run
// the same predicate, so "N match" can never disagree with the rows under it.
// The LIKE input is escaped: someone searching for "100%" is looking for a
// percent sign, not for every row containing "100".
func TestEpisodeSearchMatchesTitlesAndStatusAndPaginates(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	queue := func(source, title string) core.WorkEpisode {
		t.Helper()
		run, created, err := live.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: "COPS",
			ConversationKey: "thread:COPS:" + source, SourceKind: "watch",
			SourceID: source, Prompt: "Investigate " + source, CommitmentTitle: title,
		})
		if err != nil || !created {
			t.Fatalf("queue %s: created=%t err=%v", source, created, err)
		}
		episode, err := live.GetWorkEpisodeByRun(ctx, run.ID)
		if err != nil {
			t.Fatal(err)
		}
		return episode
	}
	queue("m1", "Checkout errors are spiking")
	second := queue("m2", "Cassandra repair overdue")
	queue("m3", "Refund is 100% complete")
	queue("m4", "Refund is 100x slower")
	// The second episode mentions checkout only in its status line.
	if err := live.SetEpisodePhase(ctx, second.ID, core.EpisodeFailed, "finished",
		"The checkout dependency broke the repair", "Review", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	matches := func(filter EpisodeFilter) ([]Item, int) {
		t.Helper()
		items, err := reader.EpisodesMatching(ctx, filter, 50)
		if err != nil {
			t.Fatal(err)
		}
		count, err := reader.CountMatching(ctx, filter)
		if err != nil {
			t.Fatal(err)
		}
		return items, count
	}

	items, count := matches(EpisodeFilter{Query: "checkout"})
	if len(items) != 2 || count != 2 {
		t.Fatalf("checkout matched %d rows, count %d, want 2 and 2", len(items), count)
	}
	items, count = matches(EpisodeFilter{Query: "checkout", State: "failed"})
	if len(items) != 1 || count != 1 || items[0].ID != second.ID {
		t.Fatalf("state filter over search = %d rows, count %d", len(items), count)
	}
	// "100%" is a literal, not a wildcard: only the row with a percent sign.
	items, count = matches(EpisodeFilter{Query: "100%"})
	if len(items) != 1 || count != 1 {
		t.Fatalf("literal %%: %d rows, count %d, want exactly the percent row", len(items), count)
	}

	// Offset pages through the same predicate rather than restarting it.
	first, err := reader.EpisodesMatching(ctx, EpisodeFilter{}, 3)
	if err != nil || len(first) != 3 {
		t.Fatalf("page one: %d rows, %v", len(first), err)
	}
	rest, err := reader.EpisodesMatching(ctx, EpisodeFilter{Offset: 3}, 3)
	if err != nil || len(rest) != 1 {
		t.Fatalf("page two: %d rows, %v", len(rest), err)
	}
	for _, earlier := range first {
		if earlier.ID == rest[0].ID {
			t.Fatal("pagination repeated a row across pages")
		}
	}
}
