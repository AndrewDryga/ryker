package store

// schemaV47 removes work_episodes.state, the last storage of the legacy
// lifecycle vocabulary.
//
// The column was dead. legacyWorkEpisodeState computed it, insert and update
// wrote it, scanWorkEpisode read it into a variable nothing used, and no query
// filtered on it — including through work_episodes_state_idx, which indexed it
// and is dropped here too.
//
// It could not be removed with DROP COLUMN: SQLite refuses that for a column in
// a CHECK constraint or an index, and this had both. Hence the rebuild, and
// hence tableRebuildMigrations[47] — work_episodes is referenced by eight tables
// with ON DELETE CASCADE, and dropping it with foreign keys on destroys every
// attempt, commitment and episode event.
//
// The DDL is spelled out rather than copied with CREATE TABLE AS SELECT. That
// shortcut loses the primary key, which leaves commitments referencing a column
// that is no longer a key: every row survives and the database is broken.
//
// work_episodes_state_idx is replaced by the same index shape on
// lifecycle_state, which is the column actually filtered on and had no index of
// its own.
const schemaV47 = `
CREATE TABLE work_episodes_rebuilt (
  id TEXT PRIMARY KEY,
  agent_run_id TEXT NOT NULL UNIQUE,
  effort TEXT NOT NULL CHECK (effort IN (
    'conversational', 'focused_check', 'operational_assessment',
    'incident_investigation', 'engineering_task'
  )),
  authority TEXT NOT NULL CHECK (authority IN (
    'read_only', 'repository_write', 'governed_operation'
  )),
  objective TEXT NOT NULL,
  required_coverage_json TEXT NOT NULL DEFAULT '[]',
  completion_criteria_json TEXT NOT NULL DEFAULT '[]',
  phase TEXT NOT NULL DEFAULT 'accepted',
  status TEXT NOT NULL DEFAULT 'Accepted',
  next_action TEXT NOT NULL DEFAULT 'Plan the work',
  progress_sequence INTEGER NOT NULL DEFAULT 0,
  last_progress_at TEXT,
  progress_due_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  completed_at TEXT,
  event_sequence INTEGER NOT NULL DEFAULT 0,
  activity TEXT NOT NULL DEFAULT 'investigating',
  lifecycle_state TEXT NOT NULL DEFAULT 'accepted',
  workspace_id TEXT NOT NULL DEFAULT '',
  parent_episode_id TEXT NOT NULL DEFAULT '',
  mode TEXT NOT NULL DEFAULT 'check',
  platform TEXT NOT NULL DEFAULT 'slack',
  channel_id TEXT NOT NULL DEFAULT '',
  thread_ts TEXT NOT NULL DEFAULT '',
  anchor_ts TEXT NOT NULL DEFAULT '',
  visibility TEXT NOT NULL DEFAULT 'channel',
  destination_channel_id TEXT NOT NULL DEFAULT '',
  destination_thread_ts TEXT NOT NULL DEFAULT '',
  destination_revision INTEGER NOT NULL DEFAULT 1,
  latest_attempt_id TEXT NOT NULL DEFAULT '',
  authority_snapshot_ref TEXT NOT NULL DEFAULT '',
  FOREIGN KEY(agent_run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
);

INSERT INTO work_episodes_rebuilt (
  id, agent_run_id, effort, authority, objective, required_coverage_json,
  completion_criteria_json, phase, status, next_action, progress_sequence,
  last_progress_at, progress_due_at, created_at, updated_at, completed_at,
  event_sequence, activity, lifecycle_state, workspace_id, parent_episode_id,
  mode, platform, channel_id, thread_ts, anchor_ts, visibility,
  destination_channel_id, destination_thread_ts, destination_revision,
  latest_attempt_id, authority_snapshot_ref
) SELECT
  id, agent_run_id, effort, authority, objective, required_coverage_json,
  completion_criteria_json, phase, status, next_action, progress_sequence,
  last_progress_at, progress_due_at, created_at, updated_at, completed_at,
  event_sequence, activity, lifecycle_state, workspace_id, parent_episode_id,
  mode, platform, channel_id, thread_ts, anchor_ts, visibility,
  destination_channel_id, destination_thread_ts, destination_revision,
  latest_attempt_id, authority_snapshot_ref
FROM work_episodes;

DROP INDEX IF EXISTS work_episodes_state_idx;
DROP TABLE work_episodes;
ALTER TABLE work_episodes_rebuilt RENAME TO work_episodes;

CREATE INDEX work_episodes_lifecycle_state_idx
  ON work_episodes(lifecycle_state, progress_due_at, updated_at);
`
