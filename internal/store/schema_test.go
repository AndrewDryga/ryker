package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// dumpSchema returns every user-defined object in the database, ordered so two
// databases built by different routes compare equal.
func dumpSchema(t *testing.T, path string) string {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.Query(`
		SELECT type, name, tbl_name, sql FROM sqlite_master
		WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var objects []string
	for rows.Next() {
		var kind, name, table, statement string
		if err := rows.Scan(&kind, &name, &table, &statement); err != nil {
			t.Fatal(err)
		}
		objects = append(objects, fmt.Sprintf("%s\t%s\t%s\t%s", table, kind, name, statement))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	sort.Strings(objects)
	return strings.Join(objects, "\n")
}

func openAt(t *testing.T, dir string) *Store {
	t.Helper()
	st, err := Open(dir)
	if err != nil {
		t.Fatalf("open %s: %v", dir, err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

// writeV39Database reproduces the last schema version that reached a deployed
// database: the baseline plus the effect ledger that migration 40 removes.
func writeV39Database(t *testing.T) string {
	t.Helper()
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(baselineSchema); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		CREATE TABLE episode_effects (
		  id TEXT PRIMARY KEY,
		  episode_id TEXT NOT NULL,
		  expected_episode_revision INTEGER NOT NULL,
		  state TEXT NOT NULL,
		  next_attempt_at TEXT,
		  created_at TEXT NOT NULL
		);
		CREATE INDEX episode_effects_due_idx
		  ON episode_effects(state, next_attempt_at, created_at);
		CREATE INDEX episode_effects_episode_idx
		  ON episode_effects(episode_id, expected_episode_revision, created_at);
		INSERT INTO schema_version(version) VALUES (39);`,
	); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	return stateDir
}

func schemaVersionOf(t *testing.T, dir string) int {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	version, err := schemaVersion(db)
	if err != nil {
		t.Fatal(err)
	}
	return version
}

// A fresh database must land on the current version directly from the
// baseline. This is the guard that keeps the baseline honest as migrations are
// appended: if someone adds schemaV41 without updating currentSchemaVersion, or
// updates the version without the statement, this fails.
func TestFreshDatabaseReachesCurrentSchemaVersion(t *testing.T) {
	dir := t.TempDir()
	openAt(t, dir)
	if version := schemaVersionOf(t, dir); version != currentSchemaVersion {
		t.Fatalf("fresh schema version = %d, want %d", version, currentSchemaVersion)
	}
}

// The baseline and the surviving migration chain must agree. A database created
// from the baseline and one upgraded from the last deployed version have to end
// up structurally identical, or an upgraded host would behave differently from
// a reinstalled one.
func TestBaselineMatchesUpgradedDeployedDatabase(t *testing.T) {
	fresh := t.TempDir()
	openAt(t, fresh)

	upgraded := writeV39Database(t)
	openAt(t, upgraded)

	freshSchema := dumpSchema(t, filepath.Join(fresh, "responder.db"))
	upgradedSchema := dumpSchema(t, filepath.Join(upgraded, "responder.db"))
	if freshSchema != upgradedSchema {
		t.Fatalf(
			"baseline and upgraded schemas differ\n--- fresh ---\n%s\n--- upgraded ---\n%s",
			freshSchema, upgradedSchema,
		)
	}
}

func TestTerraformLifecycleMigrationPreservesRulesAndRunHistory(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
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
	for version := baselineSchemaVersion + 1; version <= 49; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("apply migration %d: %v", version, err)
		}
	}
	if _, err := db.Exec(`
		INSERT INTO standing_rules (
		  id, channel_id, repository, trigger_name, action_name, source_kind,
		  enabled, source_ref, actor_id, trigger_count, last_triggered_at,
		  expires_at, created_at, updated_at
		) VALUES (
		  'rule_keep', 'COPS', 'repo', 'terraform_plan',
		  'review_terraform_plan', 'app', 1, 'slack_rule', 'UOPERATOR', 1,
		  '2026-08-08T12:00:00Z', '2026-12-01T00:00:00Z',
		  '2026-08-08T11:00:00Z', '2026-08-08T12:00:00Z'
		);
		INSERT INTO standing_rule_runs (
		  rule_id, source_input, event_id, outcome, created_at
		) VALUES (
		  'rule_keep', 'slack_plan', 'EvPlan', 'replied', '2026-08-08T12:00:00Z'
		);`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	openAt(t, stateDir)
	verify, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer verify.Close()
	if got := countRows(t, verify, "standing_rules", "standing_rule_runs"); got["standing_rules"] != 1 || got["standing_rule_runs"] != 1 {
		t.Fatalf("rows after standing-rule migration = %+v", got)
	}
	if _, err := verify.Exec(`
		INSERT INTO standing_rules (
		  id, channel_id, repository, trigger_name, action_name, source_kind,
		  source_ref, actor_id, expires_at, created_at, updated_at
		) VALUES (
		  'rule_lifecycle', 'COPS', 'repo', 'terraform_lifecycle',
		  'monitor_terraform_lifecycle', 'app', 'slack_assignment', 'UOPERATOR',
		  '2026-12-01T00:00:00Z', '2026-08-08T13:00:00Z', '2026-08-08T13:00:00Z'
		)`); err != nil {
		t.Fatalf("insert terraform lifecycle rule after migration: %v", err)
	}
}

// Migration 40 removes the unused effect ledger, and it must do so without
// disturbing rows in the tables that survive.
func TestMigrationRemovesUnusedEffectLedgerAndPreservesRows(t *testing.T) {
	dir := writeV39Database(t)
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO incidents (id, route, repository, correlation_key, title, status, workflow, created_at, updated_at)
		VALUES ('inc_keep', 'manual', 'repo', 'k', 'Keep me', 'active', 'idle', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`,
	); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	openAt(t, dir)

	if version := schemaVersionOf(t, dir); version != currentSchemaVersion {
		t.Fatalf("upgraded schema version = %d, want %d", version, currentSchemaVersion)
	}
	schema := dumpSchema(t, filepath.Join(dir, "responder.db"))
	if strings.Contains(schema, "episode_effects") {
		t.Fatal("migration 40 left the effect ledger behind")
	}
	verify, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer verify.Close()
	var title string
	if err := verify.QueryRow(`SELECT title FROM incidents WHERE id = 'inc_keep'`).Scan(&title); err != nil {
		t.Fatal(err)
	}
	if title != "Keep me" {
		t.Fatalf("incident title after migration = %q", title)
	}
}

// Upgrading a real database still takes a verified private backup first.
func TestMigrationCreatesVerifiedPrivateBackup(t *testing.T) {
	dir := writeV39Database(t)
	openAt(t, dir)

	entries, err := os.ReadDir(filepath.Join(dir, "backups"))
	if err != nil {
		t.Fatalf("read backup directory: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("backups = %d, want 1", len(entries))
	}
	name := entries[0].Name()
	expected := fmt.Sprintf("responder-v39-to-v%d-", currentSchemaVersion)
	if !strings.HasPrefix(name, expected) || !strings.HasSuffix(name, ".db") {
		t.Fatalf("backup name = %q", name)
	}
	info, err := entries[0].Info()
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("backup permissions = %o, want 600", mode)
	}
	backup := dumpSchema(t, filepath.Join(dir, "backups", name))
	if !strings.Contains(backup, "episode_effects") {
		t.Fatal("backup does not preserve the pre-migration schema")
	}
}

// A database older than the baseline must fail loudly rather than have a
// partial schema applied to it.
func TestDatabaseBelowBaselineIsRejected(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		CREATE TABLE schema_version (version INTEGER NOT NULL);
		INSERT INTO schema_version(version) VALUES (12);`,
	); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	_, err = Open(stateDir)
	if err == nil {
		t.Fatal("expected an error for a database below the supported baseline")
	}
	if !strings.Contains(err.Error(), "predates the supported baseline") {
		t.Fatalf("error = %v", err)
	}
}

// A database from a newer binary must not be downgraded in place.
func TestDatabaseNewerThanBinaryIsRejected(t *testing.T) {
	dir := writeV39Database(t)
	openAt(t, dir)
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE schema_version SET version = ?`, currentSchemaVersion+1); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(dir); err == nil || !strings.Contains(err.Error(), "newer than supported") {
		t.Fatalf("error = %v", err)
	}
}

// Feedback used to live in its own database beside this one. An upgrade must
// carry it across, or the one kind of state whose whole purpose is to survive
// until someone acts on it disappears at the moment of the upgrade.
func TestLegacyFeedbackIsAdopted(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()

	legacy, err := sql.Open("sqlite", filepath.Join(dir, "feedback.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := legacy.Exec(`
		CREATE TABLE feedback_items (
		  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, channel_id TEXT NOT NULL,
		  thread_ts TEXT NOT NULL DEFAULT '', message_ts TEXT NOT NULL DEFAULT '',
		  target_message_ts TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL,
		  source TEXT NOT NULL, category TEXT NOT NULL, sentiment TEXT NOT NULL,
		  summary TEXT NOT NULL, details TEXT NOT NULL DEFAULT '',
		  context_json BLOB NOT NULL, episode_id TEXT NOT NULL DEFAULT '',
		  agent_run_id TEXT NOT NULL DEFAULT '', source_ref TEXT NOT NULL DEFAULT '',
		  status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
		);
		INSERT INTO feedback_items VALUES
		  ('fb_old','T1','C1','','','','U1','model_sentiment','tone','suggestion',
		   'be more concise','','[]','','','','open','2026-08-01T00:00:00Z','2026-08-01T00:00:00Z');`,
	); err != nil {
		t.Fatal(err)
	}
	legacy.Close()

	st := openAt(t, dir)
	adopted, err := st.AdoptLegacyFeedback(ctx, dir)
	if err != nil {
		t.Fatal(err)
	}
	if adopted != 1 {
		t.Fatalf("adopted %d items, want 1", adopted)
	}
	items, err := st.ListOpenFeedback(ctx, "T1", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Summary != "be more concise" {
		t.Fatalf("adopted feedback = %+v", items)
	}

	// Running again must not duplicate: startup repeats on every restart.
	again, err := st.AdoptLegacyFeedback(ctx, dir)
	if err != nil {
		t.Fatal(err)
	}
	if again != 0 {
		t.Fatalf("a second adoption carried %d items across again", again)
	}

	// A deployment that never had the standalone database is not an error.
	empty := openAt(t, t.TempDir())
	if adopted, err := empty.AdoptLegacyFeedback(ctx, t.TempDir()); err != nil || adopted != 0 {
		t.Fatalf("adoption without a legacy database = %d, %v", adopted, err)
	}
}

// writeSchemaVersion50Database builds a database at the version that shipped
// before the deferred-event cleanup, so migration 51 can be exercised against
// rows in the shape the deployed databases actually hold.
func writeSchemaVersion50Database(t *testing.T) string {
	t.Helper()
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
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
	for version := baselineSchemaVersion + 1; version <= 50; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("apply migration %d: %v", version, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	return stateDir
}

// seedDeferredEventHistory writes one episode carrying the per-second waiting
// events two agent runs produced, plus the real events they were buried in.
func seedDeferredEventHistory(t *testing.T, path string) {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	for _, run := range []string{"run_first", "run_second"} {
		if _, err := db.Exec(`
			INSERT INTO agent_runs (
			  id, mode, conversation_key, source_kind, source_id, idempotency_key,
			  state, next_attempt_at, created_at, updated_at
			) VALUES (?, 'triage', 'C1', 'watch', ?, ?, 'completed',
			  '2026-08-06T00:00:00.000000000Z', '2026-08-06T00:00:00.000000000Z',
			  '2026-08-06T00:00:00.000000000Z')`,
			run, "input_"+run, "responder:run:"+run,
		); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`
		INSERT INTO work_episodes (
		  id, agent_run_id, effort, authority, objective, lifecycle_state,
		  event_sequence, created_at, updated_at
		) VALUES ('ep_wait', 'run_first', 'focused_check', 'read_only',
		  'answer the question', 'completed', 9,
		  '2026-08-06T00:00:00.000000000Z', '2026-08-06T00:00:00.000000000Z')`,
	); err != nil {
		t.Fatal(err)
	}
	insert := func(sequence int, kind, key string) {
		t.Helper()
		if _, err := db.Exec(`
			INSERT INTO work_episode_events
			  (id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at)
			VALUES (?, 'ep_wait', ?, ?, 'host', ?, '{"status":"waiting"}', ?)`,
			fmt.Sprintf("episode_event_ep_wait_%06d", sequence), sequence, kind, key,
			fmt.Sprintf("2026-08-06T00:00:%02dZ", sequence),
		); err != nil {
			t.Fatal(err)
		}
	}
	insert(1, "episode_created", "agent-run:run_first:created")
	// run_first waits three times; only the first of the three is history.
	insert(2, "phase_changed", "agent-run:run_first:deferred:2026-08-06T00:00:02Z")
	insert(3, "phase_changed", "agent-run:run_first:deferred:2026-08-06T00:00:03Z")
	insert(4, "phase_changed", "agent-run:run_first:deferred:2026-08-06T00:00:04Z")
	insert(5, "evidence_recorded", "agent-run:run_first:evidence")
	// A second attempt waiting is a separate fact and keeps its own row.
	insert(6, "phase_changed", "agent-run:run_second:deferred:2026-08-06T00:00:06Z")
	insert(7, "phase_changed", "agent-run:run_second:deferred:2026-08-06T00:00:07Z")
	insert(8, "completion_submitted", "agent-run:run_second:completed")
	// The shape the fixed emitter writes has no timestamp and is not touched.
	insert(9, "phase_changed", "agent-run:run_third:deferred")
}

// Migration 51 deletes the waiting events that were written once per second,
// keeps one per run, and leaves every other event alone.
func TestMigrationCollapsesPerSecondDeferredEvents(t *testing.T) {
	dir := writeSchemaVersion50Database(t)
	path := filepath.Join(dir, "responder.db")
	seedDeferredEventHistory(t, path)

	openAt(t, dir)

	if version := schemaVersionOf(t, dir); version != currentSchemaVersion {
		t.Fatalf("upgraded schema version = %d, want %d", version, currentSchemaVersion)
	}
	verify, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer verify.Close()
	rows, err := verify.Query(
		`SELECT sequence, kind, idempotency_key FROM work_episode_events ORDER BY sequence`,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var kept []string
	for rows.Next() {
		var sequence int
		var kind, key string
		if err := rows.Scan(&sequence, &kind, &key); err != nil {
			t.Fatal(err)
		}
		kept = append(kept, fmt.Sprintf("%d %s %s", sequence, kind, key))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"1 episode_created agent-run:run_first:created",
		"2 phase_changed agent-run:run_first:deferred:2026-08-06T00:00:02Z",
		"5 evidence_recorded agent-run:run_first:evidence",
		"6 phase_changed agent-run:run_second:deferred:2026-08-06T00:00:06Z",
		"8 completion_submitted agent-run:run_second:completed",
		"9 phase_changed agent-run:run_third:deferred",
	}
	if strings.Join(kept, "\n") != strings.Join(want, "\n") {
		t.Fatalf("events after migration 51:\n%s\nwant:\n%s",
			strings.Join(kept, "\n"), strings.Join(want, "\n"))
	}

	// The aggregate keeps allocating sequences from its own high-water mark, so
	// the gaps the deletion left cannot collide with anything written next.
	var sequence int
	if err := verify.QueryRow(
		`SELECT event_sequence FROM work_episodes WHERE id = 'ep_wait'`,
	).Scan(&sequence); err != nil {
		t.Fatal(err)
	}
	if sequence != 9 {
		t.Fatalf("episode event sequence = %d, want 9", sequence)
	}
}

// The same migration has to be a no-op on a database that never wrote a
// timestamped key, and on one it has already swept.
func TestMigrationCollapsingDeferredEventsIsSafeToRepeat(t *testing.T) {
	fresh := t.TempDir()
	openAt(t, fresh)
	db, err := sql.Open("sqlite", filepath.Join(fresh, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for range 2 {
		if _, err := db.Exec(schemaV51); err != nil {
			t.Fatalf("migration 51 on a database without deferred events: %v", err)
		}
	}

	seeded := writeSchemaVersion50Database(t)
	path := filepath.Join(seeded, "responder.db")
	seedDeferredEventHistory(t, path)
	openAt(t, seeded)
	repeat, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer repeat.Close()
	before := countRows(t, repeat, "work_episode_events")["work_episode_events"]
	if _, err := repeat.Exec(schemaV51); err != nil {
		t.Fatal(err)
	}
	if after := countRows(t, repeat, "work_episode_events")["work_episode_events"]; after != before {
		t.Fatalf("repeating migration 51 removed %d more rows", before-after)
	}
}
