package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

func TestSchemaV69PreservesUsageAndAddsReportedCost(t *testing.T) {
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
	for version := baselineSchemaVersion + 1; version <= 68; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	const stamp = "2026-08-12T12:00:00.000000000Z"
	if _, err := db.Exec(`INSERT INTO agent_runs
		(id, mode, conversation_key, source_kind, source_id, idempotency_key, state,
		 next_attempt_at, created_at, updated_at, episode_id, attempt_id)
		VALUES ('run-v68','triage','conv-v68','slack','source-v68','key-v68','completed',?,?,?,?,?)`,
		stamp, stamp, stamp, "episode-v68", "attempt-v68"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO work_episodes
		(id, agent_run_id, latest_attempt_id, effort, authority, objective,
		 phase, status, next_action, lifecycle_state, created_at, updated_at)
		VALUES ('episode-v68','run-v68','attempt-v68','focused_check','read_only','work',
		 'finished','Completed','','completed',?,?)`,
		stamp, stamp); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO episode_attempts
		(id, episode_id, agent_run_id, attempt_number, state, created_at, updated_at)
		VALUES ('attempt-v68','episode-v68','run-v68',1,'succeeded',?,?)`, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO context_manifests
		(id, episode_id, attempt_id, version, created_at, usage_input_tokens, usage_last_turn_id)
		VALUES ('manifest-v68','episode-v68','attempt-v68',1,?,123,'turn-v68')`, stamp); err != nil {
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
	var input int
	var cost float64
	var costed int
	if err := st.db.QueryRowContext(context.Background(), `SELECT usage_input_tokens,
		usage_cost_usd, usage_costed_turns FROM context_manifests WHERE id = 'manifest-v68'`).
		Scan(&input, &cost, &costed); err != nil {
		t.Fatal(err)
	}
	if input != 123 || cost != 0 || costed != 0 {
		t.Fatalf("migrated usage = input %d cost %v turns %d", input, cost, costed)
	}
}
