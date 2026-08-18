package migrationddl

// V88 adds durable deletion to the Slack outbox. Preparation blockers are
// ordinary bot messages, so retiring one after recovery must survive a process
// crash just like posting it did. SQLite cannot alter a CHECK constraint in
// place; preserve every delivery column while rebuilding it.
const V88 = `
CREATE TABLE slack_deliveries_v88 (
  id TEXT PRIMARY KEY,
  incident_id TEXT,
  operation TEXT NOT NULL CHECK (operation IN ('post', 'update', 'status', 'file', 'reaction', 'delete')),
  kind TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  message_ts TEXT NOT NULL DEFAULT '',
  body_json BLOB NOT NULL DEFAULT '',
  status_text TEXT NOT NULL DEFAULT '',
  steps_json BLOB NOT NULL DEFAULT '[]',
  coalesce_key TEXT NOT NULL DEFAULT '',
  card_version INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL CHECK (
    state IN ('pending', 'sending', 'retry', 'uncertain', 'sent', 'failed', 'superseded')
  ),
  failure_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  sequence_key TEXT NOT NULL DEFAULT '',
  sequence_index INTEGER NOT NULL DEFAULT 0,
  episode_id TEXT NOT NULL DEFAULT '',
  expected_episode_revision INTEGER NOT NULL DEFAULT 0,
  expected_destination_revision INTEGER NOT NULL DEFAULT 0,
  response_root INTEGER NOT NULL DEFAULT 0,
  agent_run_id TEXT NOT NULL DEFAULT '',
  agent_run_key TEXT NOT NULL DEFAULT '',
  source_input_id TEXT NOT NULL DEFAULT '',
  FOREIGN KEY(incident_id) REFERENCES incidents(id) ON DELETE CASCADE
);

INSERT INTO slack_deliveries_v88 (
  id, incident_id, operation, kind, channel_id, thread_ts, message_ts,
  body_json, status_text, steps_json, coalesce_key, card_version, state,
  failure_count, next_attempt_at, last_error, created_at, updated_at,
  sequence_key, sequence_index, episode_id, expected_episode_revision,
  expected_destination_revision, response_root, agent_run_id, agent_run_key,
  source_input_id
)
SELECT
  id, incident_id, operation, kind, channel_id, thread_ts, message_ts,
  body_json, status_text, steps_json, coalesce_key, card_version, state,
  failure_count, next_attempt_at, last_error, created_at, updated_at,
  sequence_key, sequence_index, episode_id, expected_episode_revision,
  expected_destination_revision, response_root, agent_run_id, agent_run_key,
  source_input_id
FROM slack_deliveries;

DROP TABLE slack_deliveries;
ALTER TABLE slack_deliveries_v88 RENAME TO slack_deliveries;

CREATE INDEX slack_deliveries_episode_idx
  ON slack_deliveries(episode_id, expected_destination_revision, state, created_at);
CREATE INDEX slack_delivery_coalesce_idx
  ON slack_deliveries(coalesce_key, state, created_at)
  WHERE coalesce_key != '';
CREATE INDEX slack_delivery_sequence_idx
  ON slack_deliveries(sequence_key, sequence_index, state)
  WHERE sequence_key != '';
CREATE INDEX slack_delivery_work_idx
  ON slack_deliveries(state, next_attempt_at, created_at);
`
