package store

const currentSchemaVersion = 10

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

const schemaV2 = `
CREATE TABLE IF NOT EXISTS slack_settings (
  scope TEXT NOT NULL,
  channel_id TEXT NOT NULL DEFAULT '',
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(scope, channel_id, name),
  CHECK (
    (scope = 'global' AND channel_id = '') OR
    (scope = 'channel' AND channel_id != '')
  )
);
`

const schemaV3 = `
ALTER TABLE incidents ADD COLUMN channel_state TEXT NOT NULL DEFAULT 'pending'
  CHECK (channel_state IN ('pending', 'active', 'archived', 'deleted', 'unreachable'));
ALTER TABLE incidents ADD COLUMN channel_state_changed_at TEXT;
ALTER TABLE incidents ADD COLUMN channel_checked_at TEXT;

UPDATE incidents
SET channel_state = 'active',
    channel_state_changed_at = updated_at,
    channel_checked_at = updated_at
WHERE channel_id != '';

CREATE INDEX IF NOT EXISTS incidents_channel_lifecycle_idx
  ON incidents(channel_state, channel_checked_at, status);
`

const schemaV4 = `
CREATE TABLE IF NOT EXISTS channel_memories (
  channel_id TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  session_id TEXT NOT NULL DEFAULT '',
  session_revision INTEGER NOT NULL DEFAULT 0,
  generation INTEGER NOT NULL DEFAULT 1,
  turn_count INTEGER NOT NULL DEFAULT 0,
  state_json TEXT NOT NULL DEFAULT '{}',
  session_started_at TEXT,
  rotated_at TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS evidence (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL DEFAULT '',
  channel_id TEXT NOT NULL DEFAULT '',
  source_input TEXT NOT NULL DEFAULT '',
  claim TEXT NOT NULL,
  observation TEXT NOT NULL,
  source_type TEXT NOT NULL,
  source_name TEXT NOT NULL,
  source_url TEXT NOT NULL DEFAULT '',
  target TEXT NOT NULL DEFAULT '',
  freshness TEXT NOT NULL DEFAULT '',
  confidence TEXT NOT NULL DEFAULT '',
  observed_at TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS evidence_incident_idx ON evidence(incident_id, created_at);
CREATE INDEX IF NOT EXISTS evidence_channel_idx ON evidence(channel_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS evidence_source_once_idx
  ON evidence(source_input, claim, source_name, target) WHERE source_input != '';

CREATE TABLE IF NOT EXISTS coverage (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL DEFAULT '',
  channel_id TEXT NOT NULL DEFAULT '',
  source_input TEXT NOT NULL DEFAULT '',
  layer TEXT NOT NULL,
  status TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '',
  detail TEXT NOT NULL DEFAULT '',
  observed_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS coverage_incident_idx ON coverage(incident_id, created_at);
CREATE INDEX IF NOT EXISTS coverage_channel_idx ON coverage(channel_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS coverage_source_once_idx
  ON coverage(source_input, layer) WHERE source_input != '';

CREATE TABLE IF NOT EXISTS timeline_events (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL DEFAULT '',
  channel_id TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  actor_id TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  evidence_ids_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS timeline_incident_idx
  ON timeline_events(incident_id, created_at);
CREATE INDEX IF NOT EXISTS timeline_channel_idx
  ON timeline_events(channel_id, created_at);

CREATE TABLE IF NOT EXISTS action_proposals (
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

CREATE INDEX IF NOT EXISTS proposals_incident_idx
  ON action_proposals(incident_id, status, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS proposals_source_once_idx
  ON action_proposals(source_input, action_name, target) WHERE source_input != '';

CREATE TABLE IF NOT EXISTS proposal_approvals (
  proposal_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  decision TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(proposal_id, actor_id),
  FOREIGN KEY(proposal_id) REFERENCES action_proposals(id)
);

CREATE TABLE IF NOT EXISTS evaluation_decisions (
  id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL,
  source_input TEXT NOT NULL,
  mode TEXT NOT NULL,
  action TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  evidence_count INTEGER NOT NULL DEFAULT 0,
  coverage_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  UNIQUE(source_input, mode)
);

CREATE INDEX IF NOT EXISTS evaluation_channel_idx
  ON evaluation_decisions(channel_id, created_at);
`

const schemaV5 = `
ALTER TABLE incidents ADD COLUMN work_kind TEXT NOT NULL DEFAULT 'incident'
  CHECK (work_kind IN ('incident', 'engineering_task'));
ALTER TABLE incidents ADD COLUMN work_scope TEXT NOT NULL DEFAULT 'room'
  CHECK (work_scope IN ('room', 'thread'));
ALTER TABLE incidents ADD COLUMN origin_channel_id TEXT NOT NULL DEFAULT '';
ALTER TABLE incidents ADD COLUMN origin_thread_ts TEXT NOT NULL DEFAULT '';

UPDATE incidents
SET work_kind = 'engineering_task',
    work_scope = CASE
      WHEN channel_id = '' AND coop_session_id = '' THEN 'thread'
      ELSE 'room'
    END,
    origin_channel_id = COALESCE((
      SELECT json_extract(signals.labels_json, '$.slack_origin_channel')
      FROM signals
      WHERE signals.incident_id = incidents.id
      ORDER BY signals.received_at
      LIMIT 1
    ), ''),
    origin_thread_ts = COALESCE((
      SELECT json_extract(signals.labels_json, '$.slack_origin_thread')
      FROM signals
      WHERE signals.incident_id = incidents.id
      ORDER BY signals.received_at
      LIMIT 1
    ), '')
WHERE route = 'manual' AND source_incident_id LIKE 'task:%';

UPDATE incidents
SET origin_channel_id = COALESCE((
      SELECT json_extract(signals.labels_json, '$.slack_origin_channel')
      FROM signals
      WHERE signals.incident_id = incidents.id
      ORDER BY signals.received_at
      LIMIT 1
    ), ''),
    origin_thread_ts = COALESCE((
      SELECT json_extract(signals.labels_json, '$.slack_origin_thread')
      FROM signals
      WHERE signals.incident_id = incidents.id
      ORDER BY signals.received_at
      LIMIT 1
    ), '')
WHERE route = 'manual' AND work_kind = 'incident';

CREATE INDEX IF NOT EXISTS incidents_conversation_idx
  ON incidents(work_scope, origin_channel_id, origin_thread_ts, status);
`

const schemaV6 = `
CREATE TABLE IF NOT EXISTS publications (
  incident_id TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  base_branch TEXT NOT NULL,
  head_branch TEXT NOT NULL,
  parent_head TEXT NOT NULL,
  candidate_tree TEXT NOT NULL,
  commit_sha TEXT NOT NULL DEFAULT '',
  remote_sha TEXT NOT NULL DEFAULT '',
  pr_number INTEGER NOT NULL DEFAULT 0,
  pr_url TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  published_at TEXT,
  FOREIGN KEY(incident_id) REFERENCES incidents(id)
);

CREATE INDEX IF NOT EXISTS publications_state_idx
  ON publications(state, updated_at);

CREATE TABLE IF NOT EXISTS coop_cleanup (
  session_id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL,
  allow_unmerged INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL,
  plan_operation_id TEXT NOT NULL DEFAULT '',
  attempts INTEGER NOT NULL DEFAULT 0,
  eligible_at TEXT NOT NULL,
  next_attempt_at TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS coop_cleanup_work_idx
  ON coop_cleanup(state, next_attempt_at, eligible_at);
`

const schemaV7 = `
CREATE TABLE IF NOT EXISTS responder_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
`

const schemaV8 = `
CREATE TABLE IF NOT EXISTS memory_entries (
  id TEXT PRIMARY KEY,
  scope_kind TEXT NOT NULL,
  scope_key TEXT NOT NULL,
  subject_key TEXT NOT NULL,
  predicate TEXT NOT NULL,
  value_json TEXT NOT NULL,
  value_hash TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  source_revision TEXT NOT NULL DEFAULT '',
  actor_id TEXT NOT NULL,
  visibility_kind TEXT NOT NULL,
  visibility_id TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(scope_kind, scope_key, subject_key, predicate),
  CHECK (scope_kind IN ('workspace', 'channel', 'repository')),
  CHECK (predicate IN (
    'alias_of',
    'repository_for_channel',
    'evidence_route',
    'entity_relationship_correction'
  )),
  CHECK (visibility_kind IN ('workspace', 'channel', 'operator'))
);

CREATE INDEX IF NOT EXISTS memory_lookup_idx
  ON memory_entries(scope_kind, scope_key, visibility_kind, visibility_id, expires_at);
CREATE INDEX IF NOT EXISTS memory_expiry_idx ON memory_entries(expires_at);
`

const schemaV9 = `
CREATE TABLE IF NOT EXISTS emisar_approvals (
  request_id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  source_input TEXT NOT NULL,
  run_id TEXT NOT NULL UNIQUE,
  operation_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  pack_ref TEXT NOT NULL,
  runner_ref TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status = 'pending_approval'),
  approval_url TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(incident_id) REFERENCES incidents(id)
);

CREATE INDEX IF NOT EXISTS emisar_approvals_incident_idx
  ON emisar_approvals(incident_id, expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS emisar_approvals_source_once_idx
  ON emisar_approvals(source_input, request_id);
`

const schemaV10 = `
CREATE TABLE IF NOT EXISTS responder_preferences (
  id TEXT PRIMARY KEY,
  scope_kind TEXT NOT NULL,
  scope_key TEXT NOT NULL,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  source_ref TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(scope_kind, scope_key, name),
  CHECK (scope_kind IN ('workspace', 'channel', 'repository', 'operator')),
  CHECK (name IN ('health_check_depth', 'response_detail')),
  CHECK (
    (name = 'health_check_depth' AND value IN ('quick', 'standard', 'deep')) OR
    (name = 'response_detail' AND value IN ('concise', 'standard', 'detailed'))
  )
);

CREATE INDEX IF NOT EXISTS responder_preferences_lookup_idx
  ON responder_preferences(scope_kind, scope_key, enabled, expires_at);
CREATE INDEX IF NOT EXISTS responder_preferences_expiry_idx
  ON responder_preferences(expires_at);

CREATE TABLE IF NOT EXISTS standing_rules (
  id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL,
  repository TEXT NOT NULL,
  trigger_name TEXT NOT NULL,
  action_name TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  source_ref TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  trigger_count INTEGER NOT NULL DEFAULT 0,
  last_triggered_at TEXT,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(channel_id, trigger_name, action_name, repository, source_kind),
  CHECK (trigger_name IN ('terraform_plan', 'deployment', 'operational_alert')),
  CHECK (action_name IN ('review_terraform_plan', 'verify_deployment', 'triage_alert')),
  CHECK (source_kind IN ('any', 'human', 'app'))
);

CREATE INDEX IF NOT EXISTS standing_rules_channel_idx
  ON standing_rules(channel_id, enabled, expires_at);
CREATE INDEX IF NOT EXISTS standing_rules_expiry_idx ON standing_rules(expires_at);

CREATE TABLE IF NOT EXISTS standing_rule_runs (
  rule_id TEXT NOT NULL,
  source_input TEXT NOT NULL,
  event_id TEXT NOT NULL,
  outcome TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(rule_id, source_input),
  FOREIGN KEY(rule_id) REFERENCES standing_rules(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS standing_rule_runs_created_idx
  ON standing_rule_runs(created_at);
`

var migrations = []string{
	schemaV1,
	schemaV2,
	schemaV3,
	schemaV4,
	schemaV5,
	schemaV6,
	schemaV7,
	schemaV8,
	schemaV9,
	schemaV10,
}
