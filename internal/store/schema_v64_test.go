package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

func TestSchemaV64AddsDurableSlackResponseIdentity(t *testing.T) {
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
	for version := baselineSchemaVersion + 1; version <= 63; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("migration %d: %v", version, err)
		}
	}
	if _, err := db.Exec(`
		INSERT INTO incidents (
		  id, route, repository, correlation_key, title, status, workflow,
		  channel_id, root_ts, created_at, updated_at
		) VALUES (
		  'inc-legacy-card', 'manual', 'repo', 'legacy-card', 'Legacy card',
		  'active', 'parked', 'C1', '1900.100',
		  '2026-08-12T00:00:00Z', '2026-08-12T00:00:02Z'
		);
		INSERT INTO slack_inputs (
		  id, envelope_id, event_id, kind, team_id, channel_id, thread_ts, message_ts,
		  user_id, text, state, next_attempt_at, received_at, updated_at
		) VALUES
		  ('legacy-sent', 'env-legacy-sent', 'event-legacy-sent', 'mention', 'T1', 'C1', '', '1700.100', 'U1', 'old question', 'done', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z'),
		  ('legacy-pending', 'env-legacy-pending', 'event-legacy-pending', 'mention', 'T1', 'C1', '', '1800.100', 'U1', 'old target', 'done', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z'),
		  ('legacy-newer', 'env-legacy-newer', 'event-legacy-newer', 'message', 'T1', 'C1', '1800.100', '1800.200', 'U1', 'new target', 'pending', '2026-08-12T00:00:01Z', '2026-08-12T00:00:01Z', '2026-08-12T00:00:01Z');
		INSERT INTO agent_runs (
		  id, mode, incident_id, channel_id, thread_ts, conversation_key, source_kind, source_id,
		  idempotency_key, state, next_attempt_at, created_at, updated_at
		) VALUES
		  ('run-legacy-sent', 'triage', NULL, 'C1', '1700.100', 'channel:C1', 'watch', 'legacy-sent', 'run:legacy-sent', 'completed', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z'),
		  ('run-legacy-pending', 'triage', NULL, 'C1', '1800.100', 'channel:C1', 'watch', 'legacy-pending', 'run:legacy-pending', 'completed', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z'),
		  ('run-legacy-card', 'engineering_task', 'inc-legacy-card', 'C1', '1900.100', 'incident:inc-legacy-card', 'incident', 'legacy-card-run', 'run:legacy-card', 'completed', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:01Z');
		INSERT INTO slack_deliveries (
		  id, operation, kind, incident_id, channel_id, thread_ts, message_ts, body_json, state,
		  next_attempt_at, created_at, updated_at
		) VALUES
		  ('watch_reply_legacy-sent', 'post', 'notice', NULL, 'C1', '', '1700.150', '{"text":"answer"}', 'sent', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z'),
		  ('watch_reply_legacy-pending', 'post', 'notice', NULL, 'C1', '', '', '{"text":"old answer"}', 'pending', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z', '2026-08-12T00:00:00Z'),
		  ('delivery_card_legacy_result', 'update', 'card', 'inc-legacy-card', 'C1', '1900.100', '1900.100', '{"text":"task result"}', 'sent', '2026-08-12T00:00:01Z', '2026-08-12T00:00:01Z', '2026-08-12T00:00:01Z'),
		  ('delivery_card_legacy_publication', 'update', 'card', 'inc-legacy-card', 'C1', '1900.100', '1900.100', '{"text":"PR merged"}', 'sent', '2026-08-12T00:00:02Z', '2026-08-12T00:00:02Z', '2026-08-12T00:00:02Z');
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
	for _, column := range []string{"response_root", "agent_run_id", "agent_run_key", "source_input_id"} {
		var count int
		if err := st.db.QueryRow(`SELECT count(*) FROM pragma_table_info('slack_deliveries') WHERE name = ?`, column).Scan(&count); err != nil || count != 1 {
			t.Fatalf("column %s count = %d, %v", column, count, err)
		}
	}
	legacy, err := st.GetSlackDelivery(context.Background(), "watch_reply_legacy-sent")
	if err != nil || !legacy.ResponseRoot || legacy.SourceInputID != "legacy-sent" ||
		legacy.AgentRunID != "run-legacy-sent" || legacy.AgentRunKey != "run:legacy-sent" {
		t.Fatalf("backfilled sent reply = %+v, %v", legacy, err)
	}
	continuing, err := st.HasRecentWatchReply(
		context.Background(), "C1", "1700.150", "1700.200", time.Time{},
	)
	if err != nil || !continuing {
		t.Fatalf("legacy reply continuation = %t, %v", continuing, err)
	}
	if _, err := st.LeaseSlackDelivery(context.Background(), nil); err == nil {
		t.Fatal("legacy pending reply bypassed newer-human suppression")
	}
	pending, err := st.GetSlackDelivery(context.Background(), "watch_reply_legacy-pending")
	if err != nil || pending.State != "superseded" || pending.SourceInputID != "legacy-pending" {
		t.Fatalf("backfilled pending reply = %+v, %v", pending, err)
	}
	for _, id := range []string{"delivery_card_legacy_result", "delivery_card_legacy_publication"} {
		card, err := st.GetSlackDelivery(context.Background(), id)
		if err != nil || card.AgentRunID != "" || card.AgentRunKey != "" {
			t.Fatalf("legacy card %s must remain causally unbound = %+v, %v", id, card, err)
		}
	}
}
