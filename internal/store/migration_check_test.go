package store

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// copyStateDir makes the copy CheckMigration is meant to run against, so a test
// can never migrate the database it is comparing to.
func copyStateDir(t *testing.T, from string) string {
	t.Helper()
	to := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(to, 0o700); err != nil {
		t.Fatal(err)
	}
	source, err := os.ReadFile(filepath.Join(from, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(to, "responder.db"), source, 0o600); err != nil {
		t.Fatal(err)
	}
	return to
}

// A migration that preserves its data reports safe, and says how much it
// preserved rather than merely saying nothing went wrong.
func TestCheckMigrationReportsAPreservingUpgradeAsSafe(t *testing.T) {
	dir := writeV39Database(t)
	effect, err := CheckMigration(copyStateDir(t, dir))
	if err != nil {
		t.Fatal(err)
	}
	if !effect.Safe() {
		t.Fatalf("a real upgrade was reported unsafe: %s", effect.Describe())
	}
	if effect.FromVersion != 39 || effect.ToVersion != currentSchemaVersion {
		t.Fatalf("versions = %d -> %d", effect.FromVersion, effect.ToVersion)
	}
	if len(effect.After) == 0 {
		t.Fatal("no tables were counted, so the check proves nothing")
	}
}

// The case this exists for: a migration that destroys rows must be caught, and
// named, before it reaches a real database.
//
// The cascade is the real shape of the danger. Dropping work_episodes takes
// eight referencing tables with it, which is invisible in any test whose
// fixtures have no child rows — so this seeds a child and requires the check to
// notice it disappear.
//
// It replaces the newest real migration rather than inventing a future one. A
// future version is rejected by the "newer than supported" guard before the
// migration ever runs, so the first version of this test passed without
// exercising the detection at all.
func TestCheckMigrationCatchesAMigrationThatDestroysRows(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	st := openAt(t, dir)
	seedEpisodeWithRun(t, st, "ep_1", "completed",
		map[string][2]string{"run_1": {"completed", "2026-08-07T12:00:00.000000000Z"}})
	if _, err := st.db.ExecContext(ctx, `
		INSERT INTO episode_attempts (id, episode_id, agent_run_id, attempt_number,
		  state, created_at, updated_at)
		VALUES ('att_1','ep_1','run_1',1,'succeeded',
		  '2026-08-07T12:00:00.000000000Z','2026-08-07T12:00:00.000000000Z')`,
	); err != nil {
		t.Fatal(err)
	}
	st.Close()

	copied := copyStateDir(t, dir)
	// Wind the copy back one version and make the newest migration destructive,
	// so Open runs it for real.
	target, err := sql.Open("sqlite", filepath.Join(copied, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := target.Exec(
		`UPDATE schema_version SET version = ?`, currentSchemaVersion-1,
	); err != nil {
		t.Fatal(err)
	}
	target.Close()

	real := migrations[currentSchemaVersion]
	wasRebuild := tableRebuildMigrations[currentSchemaVersion]
	migrations[currentSchemaVersion] = `DROP TABLE work_episodes;`
	// Foreign keys stay ON, which is what makes this the dangerous case: the
	// drop cascades and the children are deleted rather than orphaned. With
	// them off the rebuild path's foreign_key_check catches the orphans
	// instead, which is a different safety net testing itself.
	tableRebuildMigrations[currentSchemaVersion] = false
	t.Cleanup(func() {
		migrations[currentSchemaVersion] = real
		tableRebuildMigrations[currentSchemaVersion] = wasRebuild
	})

	effect, err := CheckMigration(copied)
	if err != nil {
		t.Fatalf("the check itself failed, so nothing was measured: %v", err)
	}
	if effect.Safe() {
		t.Fatalf(
			"a migration that dropped work_episodes and its children was reported safe: %s",
			effect.Describe(),
		)
	}
	if _, named := effect.Lost["episode_attempts"]; !named {
		t.Fatalf(
			"the cascade was not named; the report has to say which table lost rows: %s",
			effect.Describe(),
		)
	}
}

// A declared deletion is reported, counted, and confined to the table it named.
//
// Migration 51 is the first migration here whose purpose is to remove rows, and
// the check that guards every deploy fails any migration that loses one. The
// declaration that lets it through has to be the narrowest thing that works, or
// the next destructive migration inherits an exemption nobody re-examined.
func TestCheckMigrationReportsADeclaredDeletionWithoutExcusingAnythingElse(t *testing.T) {
	if !deletionIsIntended(50, 51, "work_episode_events") {
		t.Fatal("migration 51 does not declare the deletion it exists to perform")
	}
	// The declaration belongs to the step that made it: a host upgrading from
	// 47 runs 48 through 51 in one pass and must be covered.
	if !deletionIsIntended(47, 51, "work_episode_events") {
		t.Fatal("a multi-version upgrade does not carry the declaration")
	}
	// And it must not leak backwards onto migrations that never claimed it.
	if deletionIsIntended(47, 50, "work_episode_events") {
		t.Fatal("a version that declared nothing inherited the exemption")
	}
	for _, table := range []string{
		"work_episodes", "episode_attempts", "agent_runs", "audit_events",
	} {
		if deletionIsIntended(0, currentSchemaVersion, table) {
			t.Fatalf("%s may lose rows in a migration without anyone noticing", table)
		}
	}

	// The real thing, end to end: a database holding the shape migration 51
	// deletes reports safe, names the table, and prints the count.
	dir := t.TempDir()
	st := openAt(t, dir)
	seedEpisodeWithRun(t, st, "ep_1", "completed",
		map[string][2]string{"run_1": {"completed", "2026-08-07T12:00:00.000000000Z"}})
	for sequence, key := range map[int]string{
		2: "agent-run:run_1:deferred:2026-08-07T12:00:02Z",
		3: "agent-run:run_1:deferred:2026-08-07T12:00:03Z",
		4: "agent-run:run_1:deferred:2026-08-07T12:00:04Z",
	} {
		if _, err := st.db.Exec(`
			INSERT INTO work_episode_events
			  (id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at)
			VALUES (?, 'ep_1', ?, 'phase_changed', 'host', ?, '{}',
			  '2026-08-07T12:00:00.000000000Z')`,
			"episode_event_seed_"+key, sequence, key,
		); err != nil {
			t.Fatal(err)
		}
	}
	st.Close()

	copied := copyStateDir(t, dir)
	target, err := sql.Open("sqlite", filepath.Join(copied, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	// The copy is a current database with its version number wound back, so
	// every column the migrations above 50 added is already present and their
	// ADD COLUMN would fail on its own earlier success. The columns migrations
	// 52 and 53 add go with the version, so the copy is the shape a version-50
	// host holds.
	if _, err := target.Exec(`
		UPDATE schema_version SET version = 50;
		ALTER TABLE configuration_sessions DROP COLUMN card_ts;
		ALTER TABLE standing_rules DROP COLUMN acted_count;
		ALTER TABLE standing_rules DROP COLUMN quiet_count;`); err != nil {
		t.Fatal(err)
	}
	target.Close()

	effect, err := CheckMigration(copied)
	if err != nil {
		t.Fatal(err)
	}
	if !effect.Safe() {
		t.Fatalf("the declared deletion was reported as unsafe: %s", effect.Describe())
	}
	if effect.Removed["work_episode_events"] != 2 {
		t.Fatalf("declared removals = %+v, want two of the three repeats", effect.Removed)
	}
	if !strings.Contains(effect.Describe(), "removed 2 rows on purpose") {
		t.Fatalf("the report does not tell an operator what was deleted: %s", effect.Describe())
	}
}
