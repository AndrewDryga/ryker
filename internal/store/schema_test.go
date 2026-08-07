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
