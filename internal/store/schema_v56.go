package store

// schemaV56 records the exact before/after delta of every conversation-memory
// write. The agent result is only a proposal until ApplyWatchDecision commits;
// this audit row is written in that same transaction so the episode dashboard
// never labels a returned snapshot as saved when persistence did not happen.
const schemaV56 = `
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
