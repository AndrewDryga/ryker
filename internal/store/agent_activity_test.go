package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func activityFixture(t *testing.T) *Store {
	t.Helper()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_1", "working",
		map[string][2]string{"run_1": {"running", "2026-08-07T12:00:00.000000000Z"}})
	return st
}

func recordActivity(t *testing.T, st *Store, activity core.AgentActivity) bool {
	t.Helper()
	if activity.EpisodeID == "" {
		activity.EpisodeID = "ep_1"
	}
	if activity.AgentRunID == "" {
		activity.AgentRunID = "run_1"
	}
	if activity.OccurredAt.IsZero() {
		activity.OccurredAt = time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	}
	stored, err := st.Activity.Record(context.Background(), activity)
	if err != nil {
		t.Fatalf("record %s: %v", activity.Kind, err)
	}
	return stored
}

// The Coop event sequence is the identity of a moment, not just its order.
// Polling is at-least-once and the cursor is rewound to zero whenever it
// outruns the session, so the same narration arrives more than once by design.
func TestRecordAgentActivityIsIdempotentOnTheCoopSequence(t *testing.T) {
	st := activityFixture(t)
	first := recordActivity(t, st, core.AgentActivity{
		Sequence: 7, Kind: "tool.started", ToolCallID: "t1", Title: "Read job", ToolKind: "read",
	})
	if !first {
		t.Fatal("the first delivery was not stored")
	}
	if recordActivity(t, st, core.AgentActivity{
		Sequence: 7, Kind: "tool.started", ToolCallID: "t1", Title: "Read job", ToolKind: "read",
	}) {
		t.Fatal("a replayed event was stored a second time")
	}
	items, err := st.Activity.ListForEpisode(context.Background(), "ep_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("a replay told the story twice: %d rows", len(items))
	}
}

func TestListEpisodeActivityOrdersBySequenceNotTimestamp(t *testing.T) {
	st := activityFixture(t)
	// Same instant, which is ordinary: several frames land inside one
	// millisecond and the timestamp cannot order them.
	same := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	for _, sequence := range []int64{3, 1, 2} {
		recordActivity(t, st, core.AgentActivity{
			Sequence: sequence, Kind: "tool.started",
			Title: "call", OccurredAt: same,
		})
	}
	items, err := st.Activity.ListForEpisode(context.Background(), "ep_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 3 {
		t.Fatalf("want 3 rows, got %d", len(items))
	}
	for index, want := range []int64{1, 2, 3} {
		if items[index].Sequence != want {
			t.Fatalf("row %d has sequence %d, want %d", index, items[index].Sequence, want)
		}
	}
}

func TestRecordAgentActivityRejectsAnUnanchoredMoment(t *testing.T) {
	st := activityFixture(t)
	ctx := context.Background()
	for name, activity := range map[string]core.AgentActivity{
		"no episode":  {AgentRunID: "run_1", Sequence: 1, Kind: "tool.started"},
		"no run":      {EpisodeID: "ep_1", Sequence: 1, Kind: "tool.started"},
		"no kind":     {EpisodeID: "ep_1", AgentRunID: "run_1", Sequence: 1},
		"no sequence": {EpisodeID: "ep_1", AgentRunID: "run_1", Kind: "tool.started"},
	} {
		if _, err := st.Activity.Record(ctx, activity); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
}

// Detail is bounded JSON or nothing. A payload that is neither must not reach
// a page that will try to parse it.
func TestRecordAgentActivityDropsUnusableDetail(t *testing.T) {
	st := activityFixture(t)
	recordActivity(t, st, core.AgentActivity{
		Sequence: 1, Kind: "tool.started", Title: "call",
		Detail: []byte("this is not json"),
	})
	items, err := st.Activity.ListForEpisode(context.Background(), "ep_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("want the row without its detail, got %d rows", len(items))
	}
	if len(items[0].Detail) != 0 {
		t.Fatalf("unparseable detail was stored: %q", items[0].Detail)
	}
}

// The rows belong to the episode's story and go when it does.
func TestEpisodeActivityIsDeletedWithItsEpisode(t *testing.T) {
	st := activityFixture(t)
	ctx := context.Background()
	recordActivity(t, st, core.AgentActivity{Sequence: 1, Kind: "tool.started", Title: "call"})
	if _, err := st.db.ExecContext(ctx, `DELETE FROM work_episodes WHERE id = 'ep_1'`); err != nil {
		t.Fatal(err)
	}
	items, err := st.Activity.ListForEpisode(ctx, "ep_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("activity outlived its episode: %d rows", len(items))
	}
}
