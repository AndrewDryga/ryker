package store

import (
	"database/sql"
	"strings"
	"testing"
)

// countRows is the only thing these tests really assert: that a rebuild did not
// quietly take the children with it.
func countRows(t *testing.T, db *sql.DB, tables ...string) map[string]int {
	t.Helper()
	counts := map[string]int{}
	for _, table := range tables {
		var n int
		if err := db.QueryRow(`SELECT count(*) FROM ` + table).Scan(&n); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		counts[table] = n
	}
	return counts
}

// Dropping a parent table takes its children with it, and the migration reports
// success while it happens.
//
// This is not a test of SQLite for its own sake. work_episodes is referenced by
// eight tables with ON DELETE CASCADE, so the ordinary rebuild recipe — create,
// copy, DROP TABLE, rename — destroys every attempt, commitment and episode
// event on a real database. It was measured doing exactly that on a copy of the
// deployed one: 352 attempts, 332 commitments, 9934 events.
//
// The test exists so the next person to write a rebuild sees the trap stated as
// a failing assertion rather than discovering it in production.
func TestDroppingAParentTableCascadesToChildren(t *testing.T) {
	st := seedEpisodeAndAttempt(t)
	before := countRows(t, st.db, "episode_attempts")
	if before["episode_attempts"] != 1 {
		t.Fatalf("fixture did not land: %+v", before)
	}

	tx, err := st.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DROP TABLE work_episodes`); err != nil {
		t.Fatalf("drop parent: %v", err)
	}
	var attempts int
	if err := tx.QueryRow(`SELECT count(*) FROM episode_attempts`).Scan(&attempts); err != nil {
		t.Fatal(err)
	}
	if attempts != 0 {
		t.Fatalf(
			"dropping the parent left %d attempts; if this now survives, the "+
				"cascade is gone and a rebuild no longer needs foreign keys off",
			attempts,
		)
	}
}

// A migration listed as a table rebuild runs with foreign keys off, so the
// children survive the drop — and the verification afterwards still rejects a
// rebuild that got the parent wrong.
//
// The migration here is the naive recipe, CREATE TABLE AS SELECT, which is what
// anyone reaches for first. It loses the primary key, so commitments ends up
// referencing a column that is no longer a key. The children are all still
// there, and the database is still broken: exactly the case that would ship
// unnoticed without the check.
func TestRebuildKeepsChildrenAndStillRejectsABadRebuild(t *testing.T) {
	const version = 4001
	migrations[version] = `
		CREATE TABLE work_episodes_new AS SELECT * FROM work_episodes;
		DROP TABLE work_episodes;
		ALTER TABLE work_episodes_new RENAME TO work_episodes;`
	tableRebuildMigrations[version] = true
	t.Cleanup(func() {
		delete(migrations, version)
		delete(tableRebuildMigrations, version)
	})

	st := seedEpisodeAndAttempt(t)
	err := applySchemaStep(st.db, migrations[version], currentSchemaVersion, version)

	// Foreign keys were off, so the cascade did not fire and the children are
	// intact. Without the opt-in they would all be gone by now.
	if after := countRows(t, st.db, "episode_attempts"); after["episode_attempts"] != 1 {
		t.Fatalf("the rebuild took the children with it: %+v", after)
	}
	if err == nil {
		t.Fatal("a rebuild that dropped the primary key reported success")
	}
	if !strings.Contains(err.Error(), "foreign key") {
		t.Fatalf("error does not name the problem: %v", err)
	}
}

// A rebuild that orphans a child must fail, not leave a database that looks
// migrated. Foreign keys were off while it ran, so nothing else was going to
// catch it.
func TestRebuildMigrationFailsOnDanglingReferences(t *testing.T) {
	const version = 4002
	migrations[version] = `DELETE FROM work_episodes;`
	tableRebuildMigrations[version] = true
	t.Cleanup(func() {
		delete(migrations, version)
		delete(tableRebuildMigrations, version)
	})

	st := seedEpisodeAndAttempt(t)
	err := applySchemaStep(st.db, migrations[version], currentSchemaVersion, version)
	if err == nil {
		t.Fatal("a migration that orphaned a child reported success")
	}
	if !strings.Contains(err.Error(), "dangling references") {
		t.Fatalf("error does not name the problem: %v", err)
	}
}

// Foreign keys must be back on afterwards, or every later write runs unchecked.
func TestForeignKeysAreRestoredAfterARebuild(t *testing.T) {
	const version = 4003
	migrations[version] = `SELECT 1;`
	tableRebuildMigrations[version] = true
	t.Cleanup(func() {
		delete(migrations, version)
		delete(tableRebuildMigrations, version)
	})
	dir := t.TempDir()
	st := openAt(t, dir)
	if err := applySchemaStep(st.db, migrations[version], currentSchemaVersion, version); err != nil {
		t.Fatal(err)
	}
	var enabled int
	if err := st.db.QueryRow(`PRAGMA foreign_keys`).Scan(&enabled); err != nil {
		t.Fatal(err)
	}
	if enabled != 1 {
		t.Fatal("foreign keys were left off; every later write goes unchecked")
	}
}

// seedEpisodeAndAttempt builds the smallest parent/child pair that exercises the
// cascade: one episode and one attempt pointing at it.
func seedEpisodeAndAttempt(t *testing.T) *Store {
	t.Helper()
	st := openAt(t, t.TempDir())
	seedEpisodeWithRun(t, st, "ep_1", "completed", "completed",
		map[string][2]string{"run_1": {"completed", "2026-08-07T12:00:00.000000000Z"}})
	if _, err := st.db.Exec(`
		INSERT INTO episode_attempts (id, episode_id, agent_run_id, attempt_number,
		  state, created_at, updated_at)
		VALUES ('att_1','ep_1','run_1',1,'succeeded',
		  '2026-08-07T12:00:00.000000000Z','2026-08-07T12:00:00.000000000Z')`,
	); err != nil {
		t.Fatalf("seed attempt: %v", err)
	}
	return st
}
