// Package migrationddl holds append-only schema changes outside the store
// orchestration package. Moving the SQL does not change migration ordering.
package migrationddl

const V56 = `
CREATE TABLE conversation_memory_changes (
  id TEXT PRIMARY KEY, episode_id TEXT NOT NULL DEFAULT '',
  source_input TEXT NOT NULL UNIQUE, channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '', repository TEXT NOT NULL DEFAULT '',
  before_json BLOB NOT NULL DEFAULT '{}', after_json BLOB NOT NULL DEFAULT '{}',
  changes_json BLOB NOT NULL DEFAULT '[]', created_at TEXT NOT NULL
);

CREATE INDEX conversation_memory_changes_episode_idx
  ON conversation_memory_changes(episode_id, created_at);
`

const V58 = `
ALTER TABLE standing_rules ADD COLUMN workflow_name TEXT NOT NULL DEFAULT '';
ALTER TABLE standing_rules ADD COLUMN workflow_json BLOB NOT NULL DEFAULT '';
`
