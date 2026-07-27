package store

const currentSchemaVersion = 1

const connectionPragmas = `
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
`

const persistentPragmas = `
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
`

const schemaV1 = `
CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS incidents (
  id TEXT PRIMARY KEY,
  route TEXT NOT NULL,
  repository TEXT NOT NULL,
  correlation_key TEXT NOT NULL,
  source_incident_id TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  workflow TEXT NOT NULL,
  signal_count INTEGER NOT NULL DEFAULT 0,
  firing_count INTEGER NOT NULL DEFAULT 0,
  channel_id TEXT NOT NULL DEFAULT '',
  channel_name TEXT NOT NULL DEFAULT '',
  root_ts TEXT NOT NULL DEFAULT '',
  coop_session_id TEXT NOT NULL DEFAULT '',
  coop_fork_name TEXT NOT NULL DEFAULT '',
  coop_revision INTEGER NOT NULL DEFAULT 0,
  coop_event_sequence INTEGER NOT NULL DEFAULT 0,
  active_turn_id TEXT NOT NULL DEFAULT '',
  initial_turn_queued INTEGER NOT NULL DEFAULT 0,
  card_version INTEGER NOT NULL DEFAULT 1,
  card_rendered_version INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_firing_at TEXT,
  resolve_due_at TEXT,
  resolved_at TEXT,
  closed_at TEXT
);

CREATE INDEX IF NOT EXISTS incidents_channel_idx ON incidents(channel_id);
CREATE INDEX IF NOT EXISTS incidents_session_idx ON incidents(coop_session_id);
CREATE INDEX IF NOT EXISTS incidents_work_idx ON incidents(workflow, updated_at);
CREATE INDEX IF NOT EXISTS incidents_correlation_idx
  ON incidents(route, repository, correlation_key, updated_at);
CREATE UNIQUE INDEX IF NOT EXISTS incidents_manual_source_once_idx
  ON incidents(correlation_key) WHERE route = 'manual';

CREATE TABLE IF NOT EXISTS signals (
  route TEXT NOT NULL,
  source_id TEXT NOT NULL,
  incident_id TEXT,
  source_incident_id TEXT NOT NULL DEFAULT '',
  event_id TEXT NOT NULL,
  repository TEXT NOT NULL,
  correlation_key TEXT NOT NULL,
  status TEXT NOT NULL,
  title TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  source_url TEXT NOT NULL DEFAULT '',
  labels_json TEXT NOT NULL DEFAULT '{}',
  annotations_json TEXT NOT NULL DEFAULT '{}',
  starts_at TEXT,
  ends_at TEXT,
  received_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(route, source_id),
  FOREIGN KEY(incident_id) REFERENCES incidents(id)
);

CREATE INDEX IF NOT EXISTS signals_incident_idx ON signals(incident_id, status);

CREATE TABLE IF NOT EXISTS webhook_events (
  id TEXT PRIMARY KEY,
  route TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  body_digest TEXT NOT NULL,
  signals_json TEXT NOT NULL,
  incident_ids_json TEXT NOT NULL DEFAULT '[]',
  applied INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  received_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(route, dedupe_key)
);

CREATE INDEX IF NOT EXISTS webhook_work_idx
  ON webhook_events(state, next_attempt_at, received_at);

CREATE TABLE IF NOT EXISTS slack_inputs (
  id TEXT PRIMARY KEY,
  envelope_id TEXT NOT NULL,
  event_id TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  team_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  message_ts TEXT NOT NULL DEFAULT '',
  user_id TEXT NOT NULL DEFAULT '',
  text TEXT NOT NULL DEFAULT '',
  action_id TEXT NOT NULL DEFAULT '',
  action_value TEXT NOT NULL DEFAULT '',
  frozen_json BLOB,
  state TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  received_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(envelope_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS slack_event_once_idx
  ON slack_inputs(event_id) WHERE event_id != '';
CREATE INDEX IF NOT EXISTS slack_work_idx
  ON slack_inputs(state, next_attempt_at, received_at);

CREATE TABLE IF NOT EXISTS outbox (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  message_ts TEXT NOT NULL DEFAULT '',
  body_json BLOB NOT NULL,
  state TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(incident_id) REFERENCES incidents(id)
);

CREATE INDEX IF NOT EXISTS outbox_work_idx
  ON outbox(state, next_attempt_at, created_at);

CREATE TABLE IF NOT EXISTS turn_submissions (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_id TEXT NOT NULL,
  user_id TEXT NOT NULL DEFAULT '',
  prompt TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  expected_revision INTEGER NOT NULL DEFAULT 0,
  coop_turn_id TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(source_kind, source_id),
  FOREIGN KEY(incident_id) REFERENCES incidents(id)
);

CREATE INDEX IF NOT EXISTS turn_work_idx
  ON turn_submissions(state, created_at);
CREATE INDEX IF NOT EXISTS turn_coop_idx
  ON turn_submissions(coop_turn_id);

CREATE TABLE IF NOT EXISTS audit_events (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  actor_id TEXT NOT NULL DEFAULT '',
  object_id TEXT NOT NULL DEFAULT '',
  outcome TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS audit_incident_idx ON audit_events(incident_id, created_at);
`

var migrations = []string{
	schemaV1,
}
