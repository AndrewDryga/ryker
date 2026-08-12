package store

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
)

func TestEpisodeIdentityMigrationMergesSplitHistoryAndEnforcesIdentity(t *testing.T) {
	const (
		root  = "episode_root"
		child = "episode_run_resume"
	)
	dir := writeSchemaVersion60Database(t)
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO agent_runs (
		  id, episode_id, attempt_id, attempt_number, mode, conversation_key,
		  source_kind, source_id, idempotency_key, state, terminal_state,
		  next_attempt_at, created_at, updated_at, completed_at
		) VALUES
		  ('run_root', 'episode_root', 'attempt_root', 1, 'triage', 'thread:C1:1.0',
		   'watch', 'source_root', 'idem_root', 'completed', 'completed',
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
		   '2026-08-12T01:01:00.000000000Z', '2026-08-12T01:01:00.000000000Z'),
		  ('run_resume', 'episode_run_resume', 'attempt_resume', 2, 'triage',
		   'thread:C1:1.0', 'watch', 'episode_wakeup_resume', 'idem_resume', 'completed',
		   'completed', '2026-08-12T01:02:00.000000000Z',
		   '2026-08-12T01:02:00.000000000Z', '2026-08-12T01:03:00.000000000Z',
		   '2026-08-12T01:03:00.000000000Z');

		INSERT INTO work_episodes (
		  id, agent_run_id, latest_attempt_id, effort, authority, objective,
		  phase, status, next_action, lifecycle_state, event_sequence,
		  progress_sequence, created_at, updated_at, completed_at
		) VALUES
		  ('episode_root', 'run_root', 'attempt_resume', 'focused_check', 'read_only',
		   'check the rollout', 'investigating', 'Investigating',
		   'Complete the evidence plan', 'working', 1, 1,
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:02:00.000000000Z', NULL),
		  ('episode_run_resume', 'run_resume', 'attempt_resume', 'focused_check',
		   'read_only', 'check the rollout', 'finished', 'Completed', '', 'completed',
		   2, 1, '2026-08-12T01:02:00.000000000Z',
		   '2026-08-12T01:03:00.000000000Z', '2026-08-12T01:03:00.000000000Z');

		INSERT INTO episode_attempts (
		  id, episode_id, agent_run_id, attempt_number, state,
		  created_at, updated_at, completed_at
		) VALUES
		  ('attempt_root', 'episode_root', 'run_root', 1, 'succeeded',
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:01:00.000000000Z',
		   '2026-08-12T01:01:00.000000000Z'),
		  ('attempt_resume', 'episode_root', 'run_resume', 2, 'succeeded',
		   '2026-08-12T01:02:00.000000000Z', '2026-08-12T01:03:00.000000000Z',
		   '2026-08-12T01:03:00.000000000Z');

		INSERT INTO episode_wakeups (
		  id, episode_id, kind, state, created_at, updated_at, resolved_at
		) VALUES (
		  'resume', 'episode_root', 'timer', 'resolved',
		  '2026-08-12T01:01:00.000000000Z', '2026-08-12T01:02:00.000000000Z',
		  '2026-08-12T01:02:00.000000000Z'
		);

		INSERT INTO work_episode_events (
		  id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at
		) VALUES
		  ('event_root', 'episode_root', 1, 'episode_created', 'host', 'created:episode_root',
		   '{"phase":"accepted","summary":"Accepted"}',
		   '2026-08-12T01:00:00.000000000Z'),
		  ('event_child_duplicate', 'episode_run_resume', 1, 'episode_created', 'host',
		   'created:episode_run_resume', '{"phase":"accepted","summary":"Accepted"}',
		   '2026-08-12T01:02:00.000000000Z'),
		  ('event_child_complete', 'episode_run_resume', 2, 'phase_changed', 'host',
		   'complete-key', '{"state":"completed","phase":"finished","status":"Completed"}',
		   '2026-08-12T01:03:00.000000000Z');

		INSERT INTO work_episode_progress (id, episode_id, sequence, phase, summary, created_at)
		VALUES
		  ('progress_root', 'episode_root', 1, 'investigating', 'started',
		   '2026-08-12T01:00:00.000000000Z'),
		  ('progress_child', 'episode_run_resume', 1, 'finished', 'done',
		   '2026-08-12T01:03:00.000000000Z');

		INSERT INTO context_manifests (id, episode_id, attempt_id, version, created_at)
		VALUES
		  ('manifest_root', 'episode_root', 'attempt_root', 1,
		   '2026-08-12T01:00:00.000000000Z'),
		  ('manifest_child', 'episode_run_resume', 'attempt_resume', 1,
		   '2026-08-12T01:02:00.000000000Z');

		INSERT INTO context_manifest_refs (
		  id, manifest_id, kind, source_ref, content_digest, visibility, ordinal
		) VALUES
		  ('ref_root', 'manifest_root', 'slack', 'root-source', 'root-digest',
		   'private', 1),
		  ('ref_child', 'manifest_child', 'slack', 'child-source', 'child-digest',
		   'private', 1);

		INSERT INTO claim_assessments (id, episode_id, claim_id, status, updated_at)
		VALUES
		  ('claim_root', 'episode_root', 'change.recent', 'mixed',
		   '2026-08-12T01:01:00.000000000Z'),
		  ('claim_child', 'episode_run_resume', 'change.recent', 'supported',
		   '2026-08-12T01:03:00.000000000Z');

		INSERT INTO fixture_candidates (
		  id, episode_id, run_id, correction_class, correction, status,
		  created_at, expires_at, updated_at
		) VALUES
		  ('fixture_root', 'episode_root', 'run_root', 'cause', 'old', 'pending',
		   '2026-08-12T01:01:00.000000000Z', '2026-08-26T01:01:00.000000000Z',
		   '2026-08-12T01:01:00.000000000Z'),
		  ('fixture_child', 'episode_run_resume', 'run_resume', 'cause', 'new', 'approved',
		   '2026-08-12T01:03:00.000000000Z', '2026-08-26T01:03:00.000000000Z',
		   '2026-08-12T01:03:00.000000000Z');

		INSERT INTO commitments(episode_id, title)
		VALUES ('episode_root', 'Check the rollout'),
		       ('episode_run_resume', 'Check the rollout');
	`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	effect, err := CheckMigration(copyStateDir(t, dir))
	if err != nil || !effect.Safe() {
		t.Fatalf("migration effect = %s, %v", effect.Describe(), err)
	}
	for table, count := range map[string]int{
		"work_episodes": 1, "commitments": 1,
		"claim_assessments": 1, "fixture_candidates": 1,
	} {
		if effect.Removed[table] != count {
			t.Fatalf("removed %s = %d, want %d: %s", table, effect.Removed[table], count, effect.Describe())
		}
	}

	st := openAt(t, dir)
	episode, err := st.GetWorkEpisode(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeCompleted || episode.Phase != "finished" ||
		episode.LatestAttemptID != "attempt_resume" || episode.EventSequence != 4 ||
		episode.ProgressSequence != 3 {
		t.Fatalf("repaired root = %+v", episode)
	}
	if _, err := st.GetWorkEpisode(context.Background(), child); !errors.Is(err, ErrNotFound) {
		t.Fatalf("split child survived: %v", err)
	}

	for runID := range map[string]bool{"run_root": true, "run_resume": true} {
		run, err := st.GetAgentRun(context.Background(), runID)
		if err != nil || run.EpisodeID != root {
			t.Fatalf("repaired run %s = %+v, %v", runID, run, err)
		}
		attempt, err := st.GetEpisodeAttempt(context.Background(), run.AttemptID)
		if err != nil || attempt.EpisodeID != root || attempt.Number != run.AttemptNumber {
			t.Fatalf("repaired attempt for %s = %+v, %v", runID, attempt, err)
		}
	}

	for table, count := range map[string]int{
		"episode_attempts": 2, "work_episode_events": 4,
		"work_episode_progress": 3, "context_manifests": 2,
		"claim_assessments": 1, "fixture_candidates": 1, "commitments": 1,
	} {
		var got int
		if err := st.db.QueryRow(`SELECT count(*) FROM ` + table).Scan(&got); err != nil || got != count {
			t.Fatalf("%s rows = %d, want %d, err %v", table, got, count, err)
		}
	}
	var supported, fixtureStatus string
	if err := st.db.QueryRow(`SELECT status FROM claim_assessments`).Scan(&supported); err != nil || supported != "supported" {
		t.Fatalf("surviving claim = %q, %v", supported, err)
	}
	if err := st.db.QueryRow(`SELECT status FROM fixture_candidates`).Scan(&fixtureStatus); err != nil || fixtureStatus != "approved" {
		t.Fatalf("surviving fixture = %q, %v", fixtureStatus, err)
	}
	var distinctEventKeys int
	if err := st.db.QueryRow(`SELECT count(DISTINCT idempotency_key) FROM work_episode_events`).Scan(&distinctEventKeys); err != nil || distinctEventKeys != 4 {
		t.Fatalf("event idempotency keys = %d, %v", distinctEventKeys, err)
	}
	events, err := st.ListEpisodeEvents(context.Background(), root, 20)
	if err != nil {
		t.Fatal(err)
	}
	replayed := core.WorkEpisode{ID: root}
	for _, event := range events {
		replayed, err = episodepkg.Reduce(replayed, event)
		if err != nil {
			t.Fatalf("replay event %d (%s): %v", event.Sequence, event.Kind, err)
		}
	}
	if replayed.State != core.EpisodeCompleted || replayed.EventSequence != 4 {
		t.Fatalf("replayed episode = %+v", replayed)
	}
	var recoveredEvents int
	if err := st.db.QueryRow(`
		SELECT count(*) FROM work_episode_events
		WHERE kind = 'migration_recovered'
		  AND json_extract(payload_json, '$.merged_from_episode') = ?`, child,
	).Scan(&recoveredEvents); err != nil || recoveredEvents != 2 {
		t.Fatalf("recovered child events = %d, %v", recoveredEvents, err)
	}
	for _, manifestID := range []string{"manifest_root", "manifest_child"} {
		manifest, err := st.GetContextManifest(context.Background(), manifestID)
		if err != nil {
			t.Fatal(err)
		}
		tx, err := st.db.BeginTx(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		lineageErr := validateManifestLineage(context.Background(), tx, manifest)
		_ = tx.Rollback()
		if lineageErr != nil {
			t.Fatalf("manifest %s lineage: %v", manifestID, lineageErr)
		}
	}
	childManifest, err := st.GetContextManifest(context.Background(), "manifest_child")
	if err != nil || childManifest.Version != 2 || childManifest.ParentManifestID != "manifest_root" {
		t.Fatalf("child manifest lineage = %+v, %v", childManifest, err)
	}
	var recoveredOmissions int
	if err := st.db.QueryRow(`
		SELECT count(*) FROM context_manifest_refs
		WHERE manifest_id = 'manifest_child'
		  AND source_ref = 'root-source'
		  AND omitted_reason = 'not included in recovered split-episode context'`,
	).Scan(&recoveredOmissions); err != nil || recoveredOmissions != 1 {
		t.Fatalf("recovered manifest omissions = %d, %v", recoveredOmissions, err)
	}

	if _, err := st.db.Exec(`UPDATE agent_runs SET episode_id = 'other' WHERE id = 'run_resume'`); err == nil {
		t.Fatal("composite run/attempt episode constraint accepted a split")
	}
	other, created, err := st.QueueAgentRun(context.Background(), core.AgentRun{
		Mode: core.AgentRunTriage, ConversationKey: "thread:C1:2.0",
		SourceKind: "watch", SourceID: "other", Prompt: "other work",
	})
	if err != nil || !created {
		t.Fatalf("queue other episode = %+v, %t, %v", other, created, err)
	}
	if _, err := st.db.Exec(`UPDATE work_episodes SET latest_attempt_id = 'attempt_resume' WHERE id = ?`, other.EpisodeID); err == nil {
		t.Fatal("latest-attempt guard accepted another episode's attempt")
	}
	if err := verifyForeignKeys(st.db, currentSchemaVersion); err != nil {
		t.Fatal(err)
	}
}

func TestEpisodeIdentityMigrationRejectsUnrecognizedOrCyclicDivergence(t *testing.T) {
	for _, tc := range []struct {
		name string
		seed string
	}{
		{
			name: "unrecognized cross-wire",
			seed: `
				INSERT INTO agent_runs (
				  id, episode_id, attempt_id, attempt_number, mode, conversation_key,
				  source_kind, source_id, idempotency_key, state, next_attempt_at,
				  created_at, updated_at
				) VALUES
				  ('run_a', 'episode_a', 'attempt_a', 2, 'triage', 'thread:C1:1.0',
				   'watch', 'ordinary_input', 'idem_a', 'completed',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z'),
				  ('run_b', 'episode_b', 'attempt_b', 1, 'triage', 'thread:C1:1.0',
				   'watch', 'parent_input', 'idem_b', 'completed',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z');
				INSERT INTO work_episodes (
				  id, agent_run_id, latest_attempt_id, effort, authority, objective,
				  lifecycle_state, created_at, updated_at
				) VALUES
				  ('episode_a', 'run_a', 'attempt_a', 'focused_check', 'read_only', 'a',
				   'completed', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z'),
				  ('episode_b', 'run_b', 'attempt_b', 'focused_check', 'read_only', 'b',
				   'completed', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z');
				INSERT INTO episode_attempts (
				  id, episode_id, agent_run_id, attempt_number, state, created_at, updated_at
				) VALUES
				  ('attempt_a', 'episode_b', 'run_a', 2, 'succeeded',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z'),
				  ('attempt_b', 'episode_b', 'run_b', 1, 'succeeded',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z');`,
		},
		{
			name: "wake-up-shaped sibling cross-wire",
			seed: `
				INSERT INTO agent_runs (
				  id, episode_id, attempt_id, attempt_number, mode, conversation_key,
				  source_kind, source_id, idempotency_key, state, next_attempt_at,
				  created_at, updated_at
				) VALUES
				  ('run_a', 'episode_run_a', 'attempt_a', 2, 'triage', 'thread:C1:1.0',
				   'watch', 'episode_wakeup_wake_a', 'idem_a', 'completed',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z'),
				  ('run_b', 'episode_b', 'attempt_b', 1, 'triage', 'thread:C1:1.0',
				   'watch', 'parent_input', 'idem_b', 'completed',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z');
				INSERT INTO work_episodes (
				  id, agent_run_id, latest_attempt_id, effort, authority, objective,
				  lifecycle_state, created_at, updated_at
				) VALUES
				  ('episode_run_a', 'run_a', 'attempt_a', 'focused_check', 'read_only', 'a',
				   'completed', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z'),
				  ('episode_b', 'run_b', 'attempt_b', 'focused_check', 'read_only', 'b',
				   'completed', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z');
				INSERT INTO episode_attempts (
				  id, episode_id, agent_run_id, attempt_number, state, created_at, updated_at
				) VALUES
				  ('attempt_a', 'episode_b', 'run_a', 2, 'succeeded',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z'),
				  ('attempt_b', 'episode_b', 'run_b', 1, 'succeeded',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z');
				INSERT INTO episode_wakeups (
				  id, episode_id, kind, state, created_at, updated_at, resolved_at
				) VALUES (
				  'wake_a', 'episode_run_a', 'timer', 'resolved',
				  '2026-08-12T00:59:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				  '2026-08-12T01:00:00.000000000Z'
				);`,
		},
		{
			name: "cyclic wake-up shells",
			seed: `
				INSERT INTO agent_runs (
				  id, episode_id, attempt_id, attempt_number, mode, conversation_key,
				  source_kind, source_id, idempotency_key, state, next_attempt_at,
				  created_at, updated_at
				) VALUES
				  ('run_a', 'episode_run_a', 'attempt_a', 1, 'triage', 'thread:C1:1.0',
				   'watch', 'episode_wakeup_a', 'idem_a', 'completed',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z'),
				  ('run_b', 'episode_run_b', 'attempt_b', 1, 'triage', 'thread:C1:1.0',
				   'watch', 'episode_wakeup_b', 'idem_b', 'completed',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z');
				INSERT INTO work_episodes (
				  id, agent_run_id, latest_attempt_id, effort, authority, objective,
				  lifecycle_state, created_at, updated_at
				) VALUES
				  ('episode_run_a', 'run_a', 'attempt_a', 'focused_check', 'read_only', 'a',
				   'completed', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z'),
				  ('episode_run_b', 'run_b', 'attempt_b', 'focused_check', 'read_only', 'b',
				   'completed', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z');
				INSERT INTO episode_attempts (
				  id, episode_id, agent_run_id, attempt_number, state, created_at, updated_at
				) VALUES
				  ('attempt_a', 'episode_run_b', 'run_a', 1, 'succeeded',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z'),
				  ('attempt_b', 'episode_run_a', 'run_b', 1, 'succeeded',
				   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z');
				INSERT INTO episode_wakeups (
				  id, episode_id, kind, state, created_at, updated_at, resolved_at
				) VALUES
				  ('a', 'episode_run_b', 'timer', 'resolved',
				   '2026-08-12T00:59:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z'),
				  ('b', 'episode_run_a', 'timer', 'resolved',
				   '2026-08-12T00:59:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
				   '2026-08-12T01:00:00.000000000Z');`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := writeSchemaVersion60Database(t)
			db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := db.Exec(connectionPragmas + tc.seed); err != nil {
				t.Fatal(err)
			}
			if err := db.Close(); err != nil {
				t.Fatal(err)
			}
			if st, err := Open(dir); err == nil {
				st.Close()
				t.Fatal("migration accepted unsafe episode divergence")
			}
			if version := schemaVersionOf(t, dir); version != 60 {
				t.Fatalf("failed migration recorded schema %d, want 60", version)
			}
		})
	}
}

func TestEpisodeIdentityMigrationReplaysChainedWakeupShells(t *testing.T) {
	dir := writeSchemaVersion60Database(t)
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas + `
		INSERT INTO agent_runs (
		  id, episode_id, attempt_id, attempt_number, mode, conversation_key,
		  source_kind, source_id, idempotency_key, state, terminal_state,
		  next_attempt_at, created_at, updated_at, completed_at
		) VALUES
		  ('run_root', 'episode_root', 'attempt_root', 1, 'triage', 'thread:C1:1.0',
		   'watch', 'source_root', 'idem_root', 'completed', 'completed',
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z'),
		  ('run_child', 'episode_run_child', 'attempt_child', 2, 'triage',
		   'thread:C1:1.0', 'watch', 'episode_wakeup_child', 'idem_child',
		   'completed', 'completed', '2026-08-12T01:01:00.000000000Z',
		   '2026-08-12T01:01:00.000000000Z', '2026-08-12T01:01:00.000000000Z',
		   '2026-08-12T01:01:00.000000000Z'),
		  ('run_grand', 'episode_run_grand', 'attempt_grand', 1, 'triage',
		   'thread:C1:1.0', 'watch', 'episode_wakeup_grand', 'idem_grand',
		   'completed', 'completed', '2026-08-12T01:02:00.000000000Z',
		   '2026-08-12T01:02:00.000000000Z', '2026-08-12T01:02:00.000000000Z',
		   '2026-08-12T01:02:00.000000000Z');

		INSERT INTO work_episodes (
		  id, agent_run_id, latest_attempt_id, effort, authority, objective,
		  lifecycle_state, phase, status, event_sequence, created_at, updated_at
		) VALUES
		  ('episode_root', 'run_root', 'attempt_child', 'focused_check', 'read_only',
		   'root', 'working', 'investigating', 'Investigating', 1,
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z'),
		  ('episode_run_child', 'run_child', 'attempt_grand', 'focused_check',
		   'read_only', 'child', 'working', 'investigating', 'Investigating', 2,
		   '2026-08-12T01:01:00.000000000Z', '2026-08-12T01:01:00.000000000Z'),
		  ('episode_run_grand', 'run_grand', 'attempt_grand', 'focused_check',
		   'read_only', 'grand', 'completed', 'finished', 'Completed', 2,
		   '2026-08-12T01:02:00.000000000Z', '2026-08-12T01:02:00.000000000Z');

		INSERT INTO episode_attempts (
		  id, episode_id, agent_run_id, attempt_number, state,
		  created_at, updated_at, completed_at
		) VALUES
		  ('attempt_root', 'episode_root', 'run_root', 1, 'succeeded',
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
		   '2026-08-12T01:00:00.000000000Z'),
		  ('attempt_child', 'episode_root', 'run_child', 2, 'succeeded',
		   '2026-08-12T01:01:00.000000000Z', '2026-08-12T01:01:00.000000000Z',
		   '2026-08-12T01:01:00.000000000Z'),
		  ('attempt_grand', 'episode_run_child', 'run_grand', 1, 'succeeded',
		   '2026-08-12T01:02:00.000000000Z', '2026-08-12T01:02:00.000000000Z',
		   '2026-08-12T01:02:00.000000000Z');

		INSERT INTO episode_wakeups (
		  id, episode_id, kind, state, created_at, updated_at, resolved_at
		) VALUES
		  ('child', 'episode_root', 'timer', 'resolved',
		   '2026-08-12T00:59:00.000000000Z', '2026-08-12T01:01:00.000000000Z',
		   '2026-08-12T01:01:00.000000000Z'),
		  ('grand', 'episode_run_child', 'timer', 'resolved',
		   '2026-08-12T01:01:00.000000000Z', '2026-08-12T01:02:00.000000000Z',
		   '2026-08-12T01:02:00.000000000Z');

		INSERT INTO work_episode_events (
		  id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at
		) VALUES
		  ('event_root_created', 'episode_root', 1, 'episode_created', 'host',
		   'created:episode_root', '{"phase":"accepted","summary":"Accepted"}',
		   '2026-08-12T01:00:00.000000000Z'),
		  ('event_child_created', 'episode_run_child', 1, 'episode_created', 'host',
		   'created:episode_run_child', '{"phase":"accepted","summary":"Accepted"}',
		   '2026-08-12T01:01:00.000000000Z'),
		  ('event_child_working', 'episode_run_child', 2, 'phase_changed', 'host',
		   'child:working', '{"state":"working","phase":"investigating","status":"Investigating"}',
		   '2026-08-12T01:01:01.000000000Z'),
		  ('event_grand_created', 'episode_run_grand', 1, 'episode_created', 'host',
		   'created:episode_run_grand', '{"phase":"accepted","summary":"Accepted"}',
		   '2026-08-12T01:02:00.000000000Z'),
		  ('event_grand_complete', 'episode_run_grand', 2, 'phase_changed', 'host',
		   'grand:complete', '{"state":"completed","phase":"finished","status":"Completed"}',
		   '2026-08-12T01:02:01.000000000Z');
	`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	st := openAt(t, dir)
	episode, err := st.GetWorkEpisode(context.Background(), "episode_root")
	if err != nil || episode.State != core.EpisodeCompleted ||
		episode.LatestAttemptID != "attempt_grand" {
		t.Fatalf("repaired chained root = %+v, %v", episode, err)
	}
	for _, shell := range []string{"episode_run_child", "episode_run_grand"} {
		if _, err := st.GetWorkEpisode(context.Background(), shell); !errors.Is(err, ErrNotFound) {
			t.Fatalf("shell %s survived: %v", shell, err)
		}
	}
	events, err := st.ListEpisodeEvents(context.Background(), episode.ID, 20)
	if err != nil {
		t.Fatal(err)
	}
	replayed := core.WorkEpisode{ID: episode.ID}
	for _, event := range events {
		replayed, err = episodepkg.Reduce(replayed, event)
		if err != nil {
			t.Fatalf("replay chained event %d (%s): %v", event.Sequence, event.Kind, err)
		}
	}
	if replayed.State != core.EpisodeCompleted || replayed.EventSequence != len(events) {
		t.Fatalf("replayed chained episode = %+v, events = %d", replayed, len(events))
	}
}

func TestEpisodeIdentityMigrationPreservesLatestWakeupWaitProjection(t *testing.T) {
	dir := writeSchemaVersion60Database(t)
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(connectionPragmas + `
		INSERT INTO agent_runs (
		  id, episode_id, attempt_id, attempt_number, mode, conversation_key,
		  source_kind, source_id, idempotency_key, state, terminal_state,
		  next_attempt_at, created_at, updated_at, completed_at
		) VALUES
		  ('run_root', 'episode_root', 'attempt_root', 1, 'triage', 'thread:C1:1.0',
		   'watch', 'source_root', 'idem_root', 'completed', 'completed',
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z'),
		  ('run_wait', 'episode_run_wait', 'attempt_wait', 2, 'triage',
		   'thread:C1:1.0', 'watch', 'episode_wakeup_resume', 'idem_wait',
		   'completed', 'completed', '2026-08-12T03:00:00.000000000Z',
		   '2026-08-12T02:00:00.000000000Z', '2026-08-12T03:00:00.000000000Z',
		   '2026-08-12T03:00:00.000000000Z');

		INSERT INTO work_episodes (
		  id, agent_run_id, latest_attempt_id, effort, authority, objective,
		  lifecycle_state, phase, status, next_action, progress_due_at,
		  event_sequence, created_at, updated_at
		) VALUES
		  ('episode_root', 'run_root', 'attempt_wait', 'focused_check', 'read_only',
		   'watch terraform', 'working', 'investigating', 'Investigating',
		   'Check Terraform', NULL, 1,
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T02:00:00.000000000Z'),
		  ('episode_run_wait', 'run_wait', 'attempt_wait', 'focused_check', 'read_only',
		   'watch terraform', 'waiting_external', 'waiting_for_external_event',
		   'Waiting for Terraform', 'Resume after Terraform completes',
		   '2026-08-12T04:00:00.000000000Z', 2,
		   '2026-08-12T02:00:00.000000000Z', '2026-08-12T03:00:00.000000000Z');

		INSERT INTO episode_attempts (
		  id, episode_id, agent_run_id, attempt_number, state,
		  created_at, updated_at, completed_at
		) VALUES
		  ('attempt_root', 'episode_root', 'run_root', 1, 'succeeded',
		   '2026-08-12T01:00:00.000000000Z', '2026-08-12T01:00:00.000000000Z',
		   '2026-08-12T01:00:00.000000000Z'),
		  ('attempt_wait', 'episode_root', 'run_wait', 2, 'succeeded',
		   '2026-08-12T02:00:00.000000000Z', '2026-08-12T03:00:00.000000000Z',
		   '2026-08-12T03:00:00.000000000Z');

		INSERT INTO episode_wakeups (
		  id, episode_id, kind, due_at, state, created_at, updated_at, resolved_at
		) VALUES
		  ('resume', 'episode_root', 'timer', '2026-08-12T02:00:00.000000000Z',
		   'resolved', '2026-08-12T01:00:00.000000000Z',
		   '2026-08-12T02:00:00.000000000Z', '2026-08-12T02:00:00.000000000Z'),
		  ('followup', 'episode_run_wait', 'timer', '2026-08-12T04:00:00.000000000Z',
		   'pending', '2026-08-12T03:00:00.000000000Z',
		   '2026-08-12T03:00:00.000000000Z', NULL);

		INSERT INTO work_episode_events (
		  id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at
		) VALUES
		  ('event_root', 'episode_root', 1, 'episode_created', 'host',
		   'created:episode_root', '{"phase":"accepted","summary":"Accepted"}',
		   '2026-08-12T01:00:00.000000000Z'),
		  ('event_wait_created', 'episode_run_wait', 1, 'episode_created', 'host',
		   'created:episode_run_wait', '{"phase":"accepted","summary":"Accepted"}',
		   '2026-08-12T02:00:00.000000000Z'),
		  ('event_waiting', 'episode_run_wait', 2, 'phase_changed', 'host',
		   'wait:external',
		   '{"state":"waiting_external","phase":"waiting_for_external_event","status":"Waiting for Terraform","next_action":"Resume after Terraform completes","progress_due_at":"2026-08-12T04:00:00Z"}',
		   '2026-08-12T03:00:00.000000000Z');
	`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	st := openAt(t, dir)
	episode, err := st.GetWorkEpisode(context.Background(), "episode_root")
	if err != nil {
		t.Fatal(err)
	}
	if episode.State != core.EpisodeWaitingExternal ||
		episode.Phase != "waiting_for_external_event" ||
		episode.Status != "Waiting for Terraform" ||
		episode.NextAction != "Resume after Terraform completes" ||
		episode.ProgressDueAt.Format(time.RFC3339) != "2026-08-12T04:00:00Z" ||
		!episode.CompletedAt.IsZero() {
		t.Fatalf("repaired waiting projection = %+v", episode)
	}
	var pendingWakeups int
	if err := st.db.QueryRow(`
		SELECT count(*) FROM episode_wakeups
		WHERE id = 'followup' AND episode_id = 'episode_root' AND state = 'pending'`,
	).Scan(&pendingWakeups); err != nil || pendingWakeups != 1 {
		t.Fatalf("follow-up wakeup = %d, %v", pendingWakeups, err)
	}
	events, err := st.ListEpisodeEvents(context.Background(), episode.ID, 20)
	if err != nil {
		t.Fatal(err)
	}
	replayed := core.WorkEpisode{ID: episode.ID}
	for _, event := range events {
		replayed, err = episodepkg.Reduce(replayed, event)
		if err != nil {
			t.Fatalf("replay waiting event %d (%s): %v", event.Sequence, event.Kind, err)
		}
	}
	if replayed.State != core.EpisodeWaitingExternal ||
		replayed.ProgressDueAt.Format(time.RFC3339) != "2026-08-12T04:00:00Z" {
		t.Fatalf("replayed waiting projection = %+v", replayed)
	}
}

func TestEpisodeIdentityMigrationRejectsMalformedQualityFindingReferences(t *testing.T) {
	dir := writeSchemaVersion60Database(t)
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO quality_findings(id, episode_ids, verdict, created_at)
		VALUES ('finding_bad_episode_refs', '{}', 'confirmed',
		  '2026-08-12T01:00:00.000000000Z')`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if st, err := Open(dir); err == nil {
		st.Close()
		t.Fatal("migration accepted non-array quality finding episode references")
	}
	if version := schemaVersionOf(t, dir); version != 60 {
		t.Fatalf("failed migration recorded schema %d, want 60", version)
	}
}

func writeSchemaVersion60Database(t *testing.T) string {
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
	for version := baselineSchemaVersion + 1; version <= 60; version++ {
		if err := applySchemaStep(db, migrations[version], version-1, version); err != nil {
			t.Fatalf("apply migration %d: %v", version, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	return stateDir
}
