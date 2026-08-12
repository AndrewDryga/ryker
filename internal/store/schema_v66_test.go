package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

func TestSchemaV66BackfillsOnlyUnambiguousDecisionExecutions(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := ensurePrivateDir(stateDir); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(stateDir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	if err := applySchemaStep(db, baselineSchema, 0, baselineSchemaVersion); err != nil {
		t.Fatal(err)
	}
	for version := baselineSchemaVersion + 1; version <= 65; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	if _, err := db.Exec(`
		INSERT INTO agent_runs (
		  id, mode, channel_id, conversation_key, source_kind, source_id,
		  idempotency_key, state, next_attempt_at, created_at, updated_at
		) VALUES
		  ('run-normal', 'triage', 'C1', 'channel:C1', 'watch', 'input-normal',
		   'run:normal', 'completed', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:01Z'),
		  ('run-recovered', 'triage', 'C1', 'channel:C1', 'watch', 'input-recovered',
		   'run:recovered:recovery_2', 'completed', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:02Z');
		INSERT INTO evaluation_decisions (
		  id, channel_id, source_input, mode, action, reason, created_at
		) VALUES
		  ('eval-normal', 'C1', 'input-normal', 'live', 'reply', 'normal', '2026-08-12T00:00:01Z'),
		  ('eval-recovered', 'C1', 'input-recovered', 'live', 'reply', 'recovered', '2026-08-12T00:00:02Z');
	`); err != nil {
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
	if err := st.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
	normal, err := st.Intelligence.GetEvaluationDecision(context.Background(), "input-normal", "live")
	if err != nil || normal.AgentRunID != "run-normal" || normal.AgentRunKey != "run:normal" {
		t.Fatalf("normal decision binding = %+v, %v", normal, err)
	}
	recovered, err := st.Intelligence.GetEvaluationDecision(context.Background(), "input-recovered", "live")
	if err != nil || recovered.AgentRunID != "" || recovered.AgentRunKey != "" {
		t.Fatalf("recovered decision must remain unbound = %+v, %v", recovered, err)
	}
}
