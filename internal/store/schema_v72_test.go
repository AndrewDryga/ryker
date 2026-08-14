package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// A database migrated from v71 keeps the narration it already holds and gains a
// per-episode freshness stamp that starts empty.
//
// The column is nullable rather than defaulted because an episode that predates
// it has no last activity to claim, and a zero timestamp would claim 1970 —
// handing the overdue watchdog a fleet of runs that look decades stale on the
// first boot after the upgrade. The first moment recorded after the migration is
// what fills it in.
func TestSchemaV72AddsEpisodeActivityFreshness(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := ensurePrivateDir(stateDir); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	if err := applySchemaStep(db, baselineSchema, 0, baselineSchemaVersion); err != nil {
		t.Fatal(err)
	}
	for version := baselineSchemaVersion + 1; version <= 71; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	const stamp = "2026-08-12T12:00:00.000000000Z"
	if _, err := db.Exec(`INSERT INTO agent_runs
		(id, mode, conversation_key, source_kind, source_id, idempotency_key, state,
		 next_attempt_at, created_at, updated_at, episode_id, attempt_id)
		VALUES ('run-v71','triage','conv-v71','slack','source-v71','key-v71','running',?,?,?,?,?)`,
		stamp, stamp, stamp, "episode-v71", "attempt-v71"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO work_episodes
		(id, agent_run_id, latest_attempt_id, effort, authority, objective,
		 phase, status, next_action, lifecycle_state, created_at, updated_at)
		VALUES ('episode-v71','run-v71','attempt-v71','focused_check','read_only',
		 'Find why checkout latency doubled','working','Reading the deploy log',
		 'Name the change that did it','working',?,?)`, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO episode_attempts
		(id, episode_id, agent_run_id, attempt_number, state, created_at, updated_at)
		VALUES ('attempt-v71','episode-v71','run-v71',1,'running',?,?)`,
		stamp, stamp); err != nil {
		t.Fatal(err)
	}
	// Narration recorded before the column existed. These rows are why the
	// migration cannot conjure a stamp for the episodes already on disk: their
	// freshness would have to be derived from the story, one episode at a time.
	if _, err := db.Exec(`INSERT INTO agent_activity
		(id, episode_id, agent_run_id, session_id, sequence, kind, title,
		 occurred_at, created_at)
		VALUES ('activity-v71','episode-v71','run-v71','session-v71',4,'tool.started',
		 'Read deploy log',?,?)`, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ctx := context.Background()

	episode, err := st.GetWorkEpisode(ctx, "episode-v71")
	if err != nil {
		t.Fatal(err)
	}
	if episode.AgentRunID != "run-v71" || episode.State != core.EpisodeWorking ||
		episode.Objective != "Find why checkout latency doubled" ||
		episode.Phase != "working" || episode.Status != "Reading the deploy log" {
		t.Fatalf("the episode did not survive the migration intact: %+v", episode)
	}
	items, err := st.Activity.ListForEpisode(ctx, "episode-v71", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Title != "Read deploy log" {
		t.Fatalf("narration recorded before the migration was lost: %+v", items)
	}
	if !episode.LastActivityAt.IsZero() {
		t.Fatalf("an episode older than the column claims activity at %s",
			episode.LastActivityAt)
	}

	moment := time.Date(2026, 8, 12, 12, 5, 0, 0, time.UTC)
	if _, err := st.Activity.Record(ctx, core.AgentActivity{
		EpisodeID: "episode-v71", AgentRunID: "run-v71", SessionID: "session-v71",
		Sequence: 5, Kind: "model.thought", Title: "the 11:58 deploy looks related",
		OccurredAt: moment,
	}); err != nil {
		t.Fatal(err)
	}
	episode, err = st.GetWorkEpisode(ctx, "episode-v71")
	if err != nil {
		t.Fatal(err)
	}
	if !episode.LastActivityAt.Equal(moment) {
		t.Fatalf("freshness after one recorded moment = %s, want %s",
			episode.LastActivityAt, moment)
	}
}
