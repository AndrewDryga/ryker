package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/responder/internal/operationalkey"
)

// The projection has never stored an alert identity for an alert delivered as
// a Slack card, so every outcome on both deployments is a row recall cannot
// recognise as the same alert. Fixing the live path leaves the corpus itself
// still amnesiac, which is the half that costs money: the four earlier
// va1-nomad-oom-risk investigations are already written, and a fifth turn is
// only helped if it can find them.
//
// The backfill is exact rather than a guess. watchConversationKey has always
// written 'operation:<channel>:<correlation key>' onto the run, so the string
// the live path now derives is already on disk beside the episode.
func TestSchemaV85RecoversTheAlertIdentityOfOutcomesAlreadyWritten(t *testing.T) {
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
	for version := baselineSchemaVersion + 1; version <= 83; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	const stamp = "2026-08-13T09:00:00.000000000Z"
	const correlation = "alert-link:https://grafana.example/alerting/grafana/va1-nomad-oom-risk/view"
	rows := []struct {
		episode         string
		conversationKey string
	}{
		{"ep-alert", "operation:COPS:" + correlation},
		{"ep-chat", "channel:COPS"},
	}
	for _, row := range rows {
		if _, err := db.Exec(`INSERT INTO agent_runs
			(id, mode, channel_id, conversation_key, source_kind, source_id,
			 idempotency_key, state, next_attempt_at, created_at, updated_at)
			VALUES (?, 'triage', 'COPS', ?, 'watch', ?, ?, 'completed', ?, ?, ?)`,
			"run-"+row.episode, row.conversationKey, "input-"+row.episode,
			"key-"+row.episode, stamp, stamp, stamp); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`INSERT INTO work_episodes
			(id, agent_run_id, effort, authority, objective, channel_id,
			 lifecycle_state, created_at, updated_at)
			VALUES (?, ?, 'operational_assessment', 'read_only', 'va1 nomad OOM risk',
			 'COPS', 'completed', ?, ?)`,
			row.episode, "run-"+row.episode, stamp, stamp); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`INSERT INTO episode_outcomes
			(episode_id, channel_id, terminal_state, terminal_at, objective,
			 symptom_fingerprint, created_at)
			VALUES (?, 'COPS', 'completed', ?, 'va1 nomad OOM risk', 'nomad oom risk', ?)`,
			row.episode, stamp, stamp); err != nil {
			t.Fatal(err)
		}
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

	recovered, err := st.Intelligence.GetEpisodeOutcome(ctx, "ep-alert")
	if err != nil {
		t.Fatal(err)
	}
	if recovered.AlertGroupKey != correlation {
		t.Fatalf(
			"backfilled alert identity = %q, want the correlation key already on the run %q",
			recovered.AlertGroupKey, correlation,
		)
	}
	// The same string the live projection would now derive, so a backfilled row
	// and a freshly projected one are the same candidate.
	if recovered.AlertGroupKey != operationalkey.Key(grafanaCard()) {
		t.Fatalf(
			"backfill and live derivation disagree: %q vs %q",
			recovered.AlertGroupKey, operationalkey.Key(grafanaCard()),
		)
	}
	// A conversation turn has no alert identity and must not be given one. Its
	// conversation key is 'channel:<id>', which names a room, not an alert;
	// treating that as a group key would make every chat in a channel the same
	// alert as every other.
	untouched, err := st.Intelligence.GetEpisodeOutcome(ctx, "ep-chat")
	if err != nil {
		t.Fatal(err)
	}
	if untouched.AlertGroupKey != "" {
		t.Fatalf("a channel conversation was given an alert identity: %q", untouched.AlertGroupKey)
	}
}
