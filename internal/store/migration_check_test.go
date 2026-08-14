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
		`ALTER TABLE context_manifests DROP COLUMN usage_cost_usd;
		 ALTER TABLE context_manifests DROP COLUMN usage_costed_turns;
		 UPDATE schema_version SET version = ?`, currentSchemaVersion-1,
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
	if !deletionIsIntended(60, 61, "work_episodes") ||
		deletionIsIntended(0, 60, "work_episodes") {
		t.Fatal("duplicate episode deletion is not confined to migration 61")
	}
	for _, table := range []string{"episode_attempts", "agent_runs", "audit_events"} {
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
	// 52, 53, and 57 add go with the version, and so do the tables migrations 54-56
	// create, or their CREATE TABLE fails on its own earlier success — so the
	// copy is the shape a version-50 host holds.
	if _, err := target.Exec(`
		UPDATE schema_version SET version = 50;
		ALTER TABLE configuration_sessions DROP COLUMN card_ts;
		ALTER TABLE standing_rules DROP COLUMN acted_count;
		ALTER TABLE standing_rules DROP COLUMN quiet_count;
		ALTER TABLE standing_rules DROP COLUMN workflow_name;
		ALTER TABLE standing_rules DROP COLUMN workflow_json;
		ALTER TABLE context_manifests DROP COLUMN submitted_prompt;
		ALTER TABLE context_manifests DROP COLUMN usage_cost_usd;
		ALTER TABLE context_manifests DROP COLUMN usage_costed_turns;
		ALTER TABLE incidents DROP COLUMN changes_message_ts;
		ALTER TABLE incidents DROP COLUMN changes_stat;
		ALTER TABLE work_episodes DROP COLUMN last_activity_at;
		DROP TABLE agent_activity;
		DROP TABLE context_artifacts;
		ALTER TABLE incidents DROP COLUMN latest_update;
		ALTER TABLE incidents DROP COLUMN latest_update_run_id;
		ALTER TABLE incidents DROP COLUMN latest_update_run_key;
		ALTER TABLE incidents DROP COLUMN task_pull_request_json;
		ALTER TABLE publications DROP COLUMN attempt_input_id;
		ALTER TABLE publications DROP COLUMN failure_code;
		ALTER TABLE publications DROP COLUMN generation;
		ALTER TABLE slack_deliveries DROP COLUMN response_root;
		ALTER TABLE slack_deliveries DROP COLUMN agent_run_id;
		ALTER TABLE slack_deliveries DROP COLUMN agent_run_key;
		ALTER TABLE slack_deliveries DROP COLUMN source_input_id;
		ALTER TABLE evaluation_decisions DROP COLUMN agent_run_id;
		ALTER TABLE evaluation_decisions DROP COLUMN agent_run_key;
		DROP TABLE quality_findings;
		DROP TABLE conversation_memory_changes;
		DROP TABLE replay_cancellations;`); err != nil {
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

// A table that goes away is named even when it took no rows with it, and a
// table that goes away holding rows still fails.
//
// Migration 54 is the first migration here to drop a table since the baseline
// was collapsed, and it drops two empty ones. Empty means no rows are lost and
// the check passes — correctly — but "no rows lost across 121 tables" is not a
// description of a deploy that removed two of them. The count is printed
// beside the name so the safe case and the dangerous one read the same way,
// and neither depends on the reader having found the migration's comment.
func TestCheckMigrationNamesADroppedTableAndStillRefusesOneWithRows(t *testing.T) {
	dir := t.TempDir()
	st := openAt(t, dir)
	st.Close()

	// The copy is a current database, where migration 55 has already run. Wind
	// it back to the shape a version-54 host holds so the real migration is the
	// thing being measured.
	empty := copyStateDir(t, dir)
	windBackAndRecreateProposalTables(t, empty)
	effect, err := CheckMigration(empty)
	if err != nil {
		t.Fatal(err)
	}
	if !effect.Safe() {
		t.Fatalf("dropping two empty tables was reported unsafe: %s", effect.Describe())
	}
	if len(effect.Dropped) != 2 ||
		effect.Dropped[0] != "action_proposals" || effect.Dropped[1] != "proposal_approvals" {
		t.Fatalf("dropped tables = %+v", effect.Dropped)
	}
	if !strings.Contains(effect.Describe(), "action_proposals dropped, holding 0 rows") {
		t.Fatalf("the report does not name the dropped table: %s", effect.Describe())
	}

	// The same drop against a database that has a proposal in it must be
	// refused. A declaration cannot excuse this and none is offered.
	occupied := copyStateDir(t, dir)
	windBackAndRecreateProposalTables(t, occupied)
	seeded, err := sql.Open("sqlite", filepath.Join(occupied, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seeded.Exec(`
		INSERT INTO action_proposals (
		  id, action_name, title, summary, target, blast_radius, rollback,
		  verification, authority, risk, status, required_approvals,
		  expires_at, created_at, updated_at
		) VALUES ('act_1', 'restart', 'Restart it', 'because', 'alloc-1', 'one alloc',
		  'restore', 'probe', 'emisar', 'medium', 'pending', 1,
		  '2099-01-01T00:00:00.000000000Z', '2026-01-01T00:00:00.000000000Z',
		  '2026-01-01T00:00:00.000000000Z')`); err != nil {
		t.Fatal(err)
	}
	seeded.Close()

	effect, err = CheckMigration(occupied)
	if err != nil {
		t.Fatal(err)
	}
	if effect.Safe() {
		t.Fatalf("a table was taken away with a row in it: %s", effect.Describe())
	}
	if effect.Lost["action_proposals"] != 1 {
		t.Fatalf("the lost row was not named: %s", effect.Describe())
	}
	if deletionIsIntended(0, currentSchemaVersion, "action_proposals") {
		t.Fatal("dropping a table must never be covered by a declared deletion")
	}
}

// windBackAndRecreateProposalTables puts a current database back in the shape a
// version-53 host holds: the two proposal tables present and the version to
// match, so Open runs migration 55 for real.
func windBackAndRecreateProposalTables(t *testing.T, stateDir string) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`
		UPDATE schema_version SET version = 54;
		ALTER TABLE standing_rules DROP COLUMN workflow_name;
		ALTER TABLE standing_rules DROP COLUMN workflow_json;
		ALTER TABLE context_manifests DROP COLUMN submitted_prompt;
		ALTER TABLE context_manifests DROP COLUMN usage_cost_usd;
		ALTER TABLE context_manifests DROP COLUMN usage_costed_turns;
		ALTER TABLE incidents DROP COLUMN changes_message_ts;
		ALTER TABLE incidents DROP COLUMN changes_stat;
		ALTER TABLE work_episodes DROP COLUMN last_activity_at;
		DROP TABLE agent_activity;
		DROP TABLE context_artifacts;
		ALTER TABLE incidents DROP COLUMN latest_update;
		ALTER TABLE incidents DROP COLUMN latest_update_run_id;
		ALTER TABLE incidents DROP COLUMN latest_update_run_key;
		ALTER TABLE incidents DROP COLUMN task_pull_request_json;
		ALTER TABLE publications DROP COLUMN attempt_input_id;
		ALTER TABLE publications DROP COLUMN failure_code;
		ALTER TABLE publications DROP COLUMN generation;
		ALTER TABLE slack_deliveries DROP COLUMN response_root;
		ALTER TABLE slack_deliveries DROP COLUMN agent_run_id;
		ALTER TABLE slack_deliveries DROP COLUMN agent_run_key;
		ALTER TABLE slack_deliveries DROP COLUMN source_input_id;
		ALTER TABLE evaluation_decisions DROP COLUMN agent_run_id;
		ALTER TABLE evaluation_decisions DROP COLUMN agent_run_key;
		DROP TABLE conversation_memory_changes;
		DROP TABLE replay_cancellations;
		CREATE TABLE action_proposals (
		  id TEXT PRIMARY KEY,
		  incident_id TEXT NOT NULL DEFAULT '',
		  channel_id TEXT NOT NULL DEFAULT '',
		  source_input TEXT NOT NULL DEFAULT '',
		  action_name TEXT NOT NULL,
		  title TEXT NOT NULL,
		  summary TEXT NOT NULL,
		  target TEXT NOT NULL,
		  parameters_json TEXT NOT NULL DEFAULT '{}',
		  blast_radius TEXT NOT NULL,
		  rollback TEXT NOT NULL,
		  verification TEXT NOT NULL,
		  authority TEXT NOT NULL,
		  risk TEXT NOT NULL,
		  status TEXT NOT NULL,
		  required_approvals INTEGER NOT NULL,
		  requested_by TEXT NOT NULL DEFAULT '',
		  execution_turn TEXT NOT NULL DEFAULT '',
		  result TEXT NOT NULL DEFAULT '',
		  expires_at TEXT NOT NULL,
		  created_at TEXT NOT NULL,
		  updated_at TEXT NOT NULL
		);
		CREATE INDEX proposals_incident_idx
		  ON action_proposals(incident_id, status, created_at);
		CREATE UNIQUE INDEX proposals_source_once_idx
		  ON action_proposals(source_input, action_name, target) WHERE source_input != '';
		CREATE TABLE proposal_approvals (
		  proposal_id TEXT NOT NULL,
		  actor_id TEXT NOT NULL,
		  decision TEXT NOT NULL,
		  created_at TEXT NOT NULL,
		  PRIMARY KEY(proposal_id, actor_id),
		  FOREIGN KEY(proposal_id) REFERENCES action_proposals(id)
		);`); err != nil {
		t.Fatal(err)
	}
}
