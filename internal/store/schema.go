package store

const currentSchemaVersion = 36

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

const schemaV11 = `
ALTER TABLE slack_inputs ADD COLUMN failure_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channel_memories ADD COLUMN coop_event_sequence INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS agent_runs (
  id TEXT PRIMARY KEY,
  mode TEXT NOT NULL CHECK (mode IN ('triage', 'incident', 'engineering_task')),
  incident_id TEXT,
  channel_id TEXT NOT NULL DEFAULT '',
  thread_ts TEXT NOT NULL DEFAULT '',
  conversation_key TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_id TEXT NOT NULL,
  user_id TEXT NOT NULL DEFAULT '',
  repository TEXT NOT NULL DEFAULT '',
  prompt TEXT NOT NULL DEFAULT '',
  idempotency_key TEXT NOT NULL UNIQUE,
  session_id TEXT NOT NULL DEFAULT '',
  session_generation INTEGER NOT NULL DEFAULT 0,
  expected_revision INTEGER NOT NULL DEFAULT 0,
  coop_turn_id TEXT NOT NULL DEFAULT '',
  coop_event_sequence INTEGER NOT NULL DEFAULT 0,
  context_json BLOB NOT NULL DEFAULT '{}',
  result_json BLOB NOT NULL DEFAULT '',
  terminal_state TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL CHECK (
    state IN (
      'pending', 'preparing', 'running', 'applying', 'finalizing', 'completed',
      'failed', 'cancelled', 'superseded'
    )
  ),
  failure_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  UNIQUE(source_kind, source_id),
  FOREIGN KEY(incident_id) REFERENCES incidents(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS agent_runs_work_idx
  ON agent_runs(state, next_attempt_at, created_at);
CREATE INDEX IF NOT EXISTS agent_runs_session_idx
  ON agent_runs(session_id, state, coop_event_sequence);
CREATE INDEX IF NOT EXISTS agent_runs_conversation_idx
  ON agent_runs(conversation_key, state, created_at);

INSERT OR IGNORE INTO agent_runs (
  id, mode, incident_id, channel_id, thread_ts, conversation_key,
  source_kind, source_id, user_id, repository, prompt, idempotency_key,
  session_id, expected_revision, coop_turn_id, coop_event_sequence,
  state, failure_count, next_attempt_at, last_error, created_at, updated_at
)
SELECT
  t.id,
  CASE WHEN i.work_kind = 'engineering_task' THEN 'engineering_task' ELSE 'incident' END,
  t.incident_id,
  i.channel_id,
  CASE WHEN i.work_scope = 'thread' THEN i.origin_thread_ts ELSE i.root_ts END,
  'incident:' || t.incident_id,
  t.source_kind,
  t.source_id,
  t.user_id,
  i.repository,
  t.prompt,
  t.idempotency_key,
  i.coop_session_id,
  t.expected_revision,
  t.coop_turn_id,
  i.coop_event_sequence,
  CASE
    WHEN t.state IN ('pending', 'retry', 'submitting') THEN 'pending'
    WHEN t.state = 'submitted' THEN 'running'
    WHEN t.state IN ('completed', 'failed', 'cancelled') THEN t.state
    ELSE 'failed'
  END,
  t.attempts,
  t.next_attempt_at,
  t.last_error,
  t.created_at,
  t.updated_at
FROM turn_submissions AS t
JOIN incidents AS i ON i.id = t.incident_id;

DROP TABLE turn_submissions;
`

const schemaV12 = `
CREATE TABLE slack_deliveries (
  id TEXT PRIMARY KEY,
  incident_id TEXT,
  operation TEXT NOT NULL CHECK (operation IN ('post', 'update', 'status')),
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
  FOREIGN KEY(incident_id) REFERENCES incidents(id) ON DELETE CASCADE
);

CREATE INDEX slack_delivery_work_idx
  ON slack_deliveries(state, next_attempt_at, created_at);
CREATE INDEX slack_delivery_coalesce_idx
  ON slack_deliveries(coalesce_key, state, created_at)
  WHERE coalesce_key != '';

INSERT INTO slack_deliveries (
  id, incident_id, operation, kind, channel_id, thread_ts, message_ts,
  body_json, state, failure_count, next_attempt_at, last_error,
  created_at, updated_at
)
SELECT
  id, incident_id, 'post', kind, channel_id, thread_ts, message_ts,
  body_json, state, attempts, next_attempt_at, last_error,
  created_at, updated_at
FROM outbox;

DROP TABLE outbox;
`

const schemaV13 = `
CREATE TABLE slack_status_generations (
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL,
  generation INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(channel_id, thread_ts)
);

CREATE TABLE work_items (
  kind TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  lane TEXT NOT NULL CHECK (lane IN ('control', 'background', 'maintenance')),
  conversation_key TEXT NOT NULL DEFAULT '',
  priority INTEGER NOT NULL DEFAULT 100,
  state TEXT NOT NULL CHECK (state IN ('pending', 'running', 'failed')),
  failure_count INTEGER NOT NULL DEFAULT 0,
  available_at TEXT NOT NULL,
  lease_expires_at TEXT,
  lease_token TEXT NOT NULL DEFAULT '',
  rerun_at TEXT,
  deadline_at TEXT,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(kind, subject_id)
);

CREATE INDEX work_items_due_idx
  ON work_items(lane, state, available_at, priority, created_at);
CREATE INDEX work_items_conversation_idx
  ON work_items(conversation_key, state, lease_expires_at)
  WHERE conversation_key != '';
`

const schemaV14 = `
CREATE TABLE channel_configurations (
  channel_id TEXT PRIMARY KEY,
  participation TEXT NOT NULL CHECK (participation IN ('mentions', 'proactive', 'shadow')),
  repository TEXT NOT NULL,
  alert_policy TEXT NOT NULL CHECK (alert_policy IN ('reply', 'offer', 'automatic')),
  invite_users_json TEXT NOT NULL DEFAULT '[]',
  invite_user_groups_json TEXT NOT NULL DEFAULT '[]',
  actor_id TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE configuration_sessions (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  initiator_id TEXT NOT NULL DEFAULT '',
  step TEXT NOT NULL CHECK (
    step IN ('participation', 'repository', 'alerts', 'audience', 'confirm')
  ),
  status TEXT NOT NULL CHECK (
    status IN ('asking', 'confirming', 'saved', 'cancelled', 'expired')
  ),
  draft_json BLOB NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX configuration_sessions_active_channel_idx
  ON configuration_sessions(channel_id)
  WHERE status IN ('asking', 'confirming');
CREATE INDEX configuration_sessions_expiry_idx
  ON configuration_sessions(status, expires_at);
`

const schemaV15 = `
CREATE TABLE slack_channel_memberships (
  channel_id TEXT PRIMARY KEY,
  channel_name TEXT NOT NULL DEFAULT '',
  private INTEGER NOT NULL DEFAULT 0 CHECK (private IN (0, 1)),
  present INTEGER NOT NULL DEFAULT 0 CHECK (present IN (0, 1)),
  onboarding_state TEXT NOT NULL DEFAULT 'complete' CHECK (
    onboarding_state IN ('pending', 'complete')
  ),
  joined_at TEXT,
  observed_at TEXT NOT NULL
);

CREATE INDEX slack_channel_memberships_onboarding_idx
  ON slack_channel_memberships(onboarding_state, present, joined_at)
  WHERE onboarding_state = 'pending' AND present = 1;
`

const schemaV16 = `
ALTER TABLE configuration_sessions
  ADD COLUMN response_thread_ts TEXT NOT NULL DEFAULT '';
ALTER TABLE configuration_sessions
  ADD COLUMN thread_roots_json TEXT NOT NULL DEFAULT '[]';

UPDATE configuration_sessions
SET thread_roots_json = CASE
  WHEN thread_ts = '' THEN '[]'
  ELSE '["' || thread_ts || '"]'
END;
`

const schemaV17 = `
CREATE TABLE commitments (
  agent_run_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  FOREIGN KEY(agent_run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
);

INSERT OR IGNORE INTO commitments (agent_run_id, title)
SELECT
  id,
  CASE
    WHEN mode = 'incident' THEN 'Investigate incident'
    WHEN mode = 'engineering_task' THEN 'Complete engineering task'
    ELSE 'Answer Slack request'
  END
FROM agent_runs;
`

const schemaV18 = `
CREATE TABLE conversation_memories (
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  repository TEXT NOT NULL,
  last_message_ts TEXT NOT NULL DEFAULT '',
  state_json TEXT NOT NULL DEFAULT '{}',
  updated_at TEXT NOT NULL,
  PRIMARY KEY(channel_id, thread_ts)
);

CREATE INDEX conversation_memories_recent_idx
  ON conversation_memories(updated_at DESC);
CREATE INDEX conversation_memories_repository_idx
  ON conversation_memories(repository, updated_at DESC);
`

const schemaV19 = `
ALTER TABLE slack_inputs
  ADD COLUMN attachments_json BLOB NOT NULL DEFAULT '[]';
`

const schemaV20 = `
CREATE TABLE conversation_sessions (
  channel_id TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  policy TEXT NOT NULL,
  session_id TEXT NOT NULL DEFAULT '',
  session_revision INTEGER NOT NULL DEFAULT 0,
  coop_event_sequence INTEGER NOT NULL DEFAULT 0,
  generation INTEGER NOT NULL DEFAULT 1,
  turn_count INTEGER NOT NULL DEFAULT 0,
  session_started_at TEXT,
  rotated_at TEXT,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX conversation_sessions_session_idx
  ON conversation_sessions(session_id)
  WHERE session_id != '';

CREATE TABLE conversation_routes (
  channel_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  active_thread_ts TEXT NOT NULL DEFAULT '',
  previous_thread_ts TEXT NOT NULL DEFAULT '',
  explicit INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(channel_id, user_id)
);

CREATE INDEX conversation_routes_updated_idx
  ON conversation_routes(updated_at);
`

const schemaV21 = `
ALTER TABLE responder_preferences RENAME TO responder_preferences_v20;

CREATE TABLE responder_preferences (
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
  CHECK (name != 'response_location' OR scope_kind != 'repository'),
  CHECK (name IN ('health_check_depth', 'response_detail', 'response_location')),
  CHECK (
    (name = 'health_check_depth' AND value IN ('quick', 'standard', 'deep')) OR
    (name = 'response_detail' AND value IN ('concise', 'standard', 'detailed')) OR
    (name = 'response_location' AND value IN ('follow_context', 'prefer_thread', 'prefer_channel'))
  )
);

INSERT INTO responder_preferences (
  id, scope_kind, scope_key, name, value, enabled, source_ref, actor_id,
  expires_at, created_at, updated_at
)
SELECT
  id, scope_kind, scope_key, name, value, enabled, source_ref, actor_id,
  expires_at, created_at, updated_at
FROM responder_preferences_v20;

DROP TABLE responder_preferences_v20;

CREATE INDEX responder_preferences_lookup_idx
  ON responder_preferences(scope_kind, scope_key, enabled, expires_at);
CREATE INDEX responder_preferences_expiry_idx
  ON responder_preferences(expires_at);

ALTER TABLE memory_entries RENAME TO memory_entries_v20;

CREATE TABLE memory_entries (
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
    'entity_relationship_correction',
    'guidance'
  )),
  CHECK (visibility_kind IN ('workspace', 'channel', 'operator'))
);

INSERT INTO memory_entries (
  id, scope_kind, scope_key, subject_key, predicate, value_json, value_hash,
  source_ref, source_revision, actor_id, visibility_kind, visibility_id,
  expires_at, created_at, updated_at
)
SELECT
  id, scope_kind, scope_key, subject_key, predicate, value_json, value_hash,
  source_ref, source_revision, actor_id, visibility_kind, visibility_id,
  expires_at, created_at, updated_at
FROM memory_entries_v20;

DROP TABLE memory_entries_v20;

CREATE INDEX memory_lookup_idx
  ON memory_entries(scope_kind, scope_key, visibility_kind, visibility_id, expires_at);
CREATE INDEX memory_expiry_idx ON memory_entries(expires_at);
`

const schemaV22 = `
ALTER TABLE slack_deliveries RENAME TO slack_deliveries_v21;

CREATE TABLE slack_deliveries (
  id TEXT PRIMARY KEY,
  incident_id TEXT,
  operation TEXT NOT NULL CHECK (operation IN ('post', 'update', 'status', 'file')),
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
  FOREIGN KEY(incident_id) REFERENCES incidents(id) ON DELETE CASCADE
);

INSERT INTO slack_deliveries (
  id, incident_id, operation, kind, channel_id, thread_ts, message_ts,
  body_json, status_text, steps_json, coalesce_key, card_version, state,
  failure_count, next_attempt_at, last_error, created_at, updated_at
)
SELECT
  id, incident_id, operation, kind, channel_id, thread_ts, message_ts,
  body_json, status_text, steps_json, coalesce_key, card_version, state,
  failure_count, next_attempt_at, last_error, created_at, updated_at
FROM slack_deliveries_v21;

DROP TABLE slack_deliveries_v21;

CREATE INDEX slack_delivery_work_idx
  ON slack_deliveries(state, next_attempt_at, created_at);
CREATE INDEX slack_delivery_coalesce_idx
  ON slack_deliveries(coalesce_key, state, created_at)
  WHERE coalesce_key != '';
`

const schemaV23 = `
ALTER TABLE emisar_approvals RENAME TO emisar_approvals_v22;

CREATE TABLE emisar_approvals (
  request_id TEXT PRIMARY KEY,
  incident_id TEXT,
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
  FOREIGN KEY(incident_id) REFERENCES incidents(id) ON DELETE CASCADE
);

INSERT INTO emisar_approvals (
  request_id, incident_id, channel_id, source_input, run_id, operation_id,
  action_id, pack_ref, runner_ref, status, approval_url, expires_at,
  created_at, updated_at
)
SELECT
  request_id, incident_id, channel_id, source_input, run_id, operation_id,
  action_id, pack_ref, runner_ref, status, approval_url, expires_at,
  created_at, updated_at
FROM emisar_approvals_v22;

DROP TABLE emisar_approvals_v22;

CREATE INDEX emisar_approvals_incident_idx
  ON emisar_approvals(incident_id, expires_at);
CREATE INDEX emisar_approvals_channel_idx
  ON emisar_approvals(channel_id, expires_at);
CREATE UNIQUE INDEX emisar_approvals_source_once_idx
  ON emisar_approvals(source_input, request_id);
`

const schemaV24 = `
ALTER TABLE emisar_approvals RENAME TO emisar_approvals_v23;

CREATE TABLE emisar_approvals (
  request_id TEXT PRIMARY KEY,
  incident_id TEXT,
  channel_id TEXT NOT NULL,
  source_input TEXT NOT NULL,
  requested_by TEXT NOT NULL,
  delivery_id TEXT NOT NULL DEFAULT '',
  message_ts TEXT NOT NULL DEFAULT '',
  run_id TEXT NOT NULL UNIQUE,
  operation_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  pack_ref TEXT NOT NULL,
  runner_ref TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'pending', 'pending_approval', 'sent', 'running', 'cancelling',
    'success', 'failed', 'error', 'validation_failed', 'unknown_action',
    'cancelled', 'timed_out', 'refused', 'denied'
  )),
  approval_url TEXT NOT NULL,
  run_url TEXT NOT NULL DEFAULT '',
  last_error TEXT NOT NULL DEFAULT '',
  failure_count INTEGER NOT NULL DEFAULT 0,
  continuation_queued INTEGER NOT NULL DEFAULT 0 CHECK (continuation_queued IN (0, 1)),
  next_check_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  terminal_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(incident_id) REFERENCES incidents(id) ON DELETE CASCADE
);

INSERT INTO emisar_approvals (
  request_id, incident_id, channel_id, source_input, requested_by,
  delivery_id, message_ts, run_id, operation_id, action_id, pack_ref,
  runner_ref, status, approval_url, next_check_at, expires_at,
  created_at, updated_at
)
SELECT
  approval.request_id,
  approval.incident_id,
  approval.channel_id,
  approval.source_input,
  COALESCE((
    SELECT input.user_id FROM slack_inputs AS input
    WHERE input.id = approval.source_input
  ), ''),
  COALESCE((
    SELECT delivery.id FROM slack_deliveries AS delivery
    WHERE delivery.id = 'watch_reply_' || approval.source_input
       OR delivery.id = (
         SELECT 'out_run_' || run.id FROM agent_runs AS run
         WHERE run.source_id = approval.source_input
         ORDER BY run.created_at DESC LIMIT 1
       )
    ORDER BY CASE WHEN delivery.id = 'watch_reply_' || approval.source_input THEN 0 ELSE 1 END
    LIMIT 1
  ), ''),
  COALESCE((
    SELECT delivery.message_ts FROM slack_deliveries AS delivery
    WHERE delivery.id = 'watch_reply_' || approval.source_input
       OR delivery.id = (
         SELECT 'out_run_' || run.id FROM agent_runs AS run
         WHERE run.source_id = approval.source_input
         ORDER BY run.created_at DESC LIMIT 1
       )
    ORDER BY CASE WHEN delivery.id = 'watch_reply_' || approval.source_input THEN 0 ELSE 1 END
    LIMIT 1
  ), ''),
  approval.run_id,
  approval.operation_id,
  approval.action_id,
  approval.pack_ref,
  approval.runner_ref,
  approval.status,
  approval.approval_url,
  approval.updated_at,
  approval.expires_at,
  approval.created_at,
  approval.updated_at
FROM emisar_approvals_v23 AS approval;

DROP TABLE emisar_approvals_v23;

CREATE INDEX emisar_approvals_incident_idx
  ON emisar_approvals(incident_id, expires_at);
CREATE INDEX emisar_approvals_channel_idx
  ON emisar_approvals(channel_id, expires_at);
CREATE INDEX emisar_approvals_monitor_idx
  ON emisar_approvals(continuation_queued, next_check_at, created_at);
CREATE UNIQUE INDEX emisar_approvals_source_once_idx
  ON emisar_approvals(source_input, request_id);
`

const schemaV25 = `
ALTER TABLE memory_entries ADD COLUMN last_recalled_at TEXT;
ALTER TABLE memory_entries ADD COLUMN recall_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN last_reviewed_at TEXT;

ALTER TABLE conversation_memories ADD COLUMN last_recalled_at TEXT;
ALTER TABLE conversation_memories ADD COLUMN recall_count INTEGER NOT NULL DEFAULT 0;

CREATE TABLE memory_rollups (
  id TEXT PRIMARY KEY,
  scope_kind TEXT NOT NULL CHECK (scope_kind IN ('channel', 'repository')),
  scope_key TEXT NOT NULL,
  repository TEXT NOT NULL,
  period_start TEXT NOT NULL,
  period_end TEXT NOT NULL,
  state_json TEXT NOT NULL,
  source_refs_json TEXT NOT NULL,
  source_count INTEGER NOT NULL,
  last_recalled_at TEXT,
  recall_count INTEGER NOT NULL DEFAULT 0,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(scope_kind, scope_key, period_start)
);

CREATE INDEX memory_rollups_context_idx
  ON memory_rollups(scope_kind, scope_key, period_end DESC, expires_at);
CREATE INDEX memory_rollups_expiry_idx ON memory_rollups(expires_at);

CREATE TABLE memory_review_items (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('stale', 'duplicate')),
  entry_ids_json TEXT NOT NULL,
  reason TEXT NOT NULL,
  source_digest TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'kept', 'applied', 'dismissed')
  ),
  reviewed_by TEXT NOT NULL DEFAULT '',
  reviewed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX memory_review_pending_idx
  ON memory_review_items(status, created_at);

CREATE TABLE memory_supersessions (
  id TEXT PRIMARY KEY,
  entry_id TEXT NOT NULL,
  previous_value_hash TEXT NOT NULL,
  replacement_value_hash TEXT NOT NULL,
  reason TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX memory_supersessions_entry_idx
  ON memory_supersessions(entry_id, created_at DESC);
`

const schemaV26 = `
CREATE TABLE scheduled_tasks (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  repository TEXT NOT NULL,
  title TEXT NOT NULL,
  prompt TEXT NOT NULL,
  recurrence TEXT NOT NULL CHECK (recurrence IN ('once', 'interval', 'daily', 'weekly', 'monthly')),
  start_at TEXT NOT NULL,
  interval_seconds INTEGER NOT NULL DEFAULT 0,
  weekdays_json TEXT NOT NULL DEFAULT '[]',
  day_of_month INTEGER NOT NULL DEFAULT 0,
  local_time TEXT NOT NULL DEFAULT '',
  timezone TEXT NOT NULL DEFAULT 'UTC',
  catch_up TEXT NOT NULL DEFAULT 'latest' CHECK (catch_up IN ('latest', 'skip')),
  enabled INTEGER NOT NULL DEFAULT 1,
  actor_id TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  next_run_at TEXT,
  last_run_at TEXT,
  last_outcome TEXT NOT NULL DEFAULT '',
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX scheduled_tasks_due_idx
  ON scheduled_tasks(enabled, next_run_at, expires_at);
CREATE INDEX scheduled_tasks_channel_idx
  ON scheduled_tasks(channel_id, expires_at, updated_at DESC);
CREATE UNIQUE INDEX scheduled_tasks_source_once_idx
  ON scheduled_tasks(team_id, channel_id, source_ref);

CREATE TABLE scheduled_task_runs (
  task_id TEXT NOT NULL,
  scheduled_for TEXT NOT NULL,
  source_input TEXT NOT NULL DEFAULT '',
  agent_run_id TEXT NOT NULL DEFAULT '',
  outcome TEXT NOT NULL CHECK (outcome IN ('queued', 'running', 'completed', 'failed', 'skipped_missed', 'skipped_overlap', 'skipped_unauthorized')),
  last_error TEXT NOT NULL DEFAULT '',
  started_at TEXT,
  completed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(task_id, scheduled_for),
  FOREIGN KEY(task_id) REFERENCES scheduled_tasks(id) ON DELETE CASCADE
);

CREATE INDEX scheduled_task_runs_state_idx
  ON scheduled_task_runs(outcome, updated_at);
CREATE UNIQUE INDEX scheduled_task_runs_input_once_idx
  ON scheduled_task_runs(source_input) WHERE source_input != '';
`

const schemaV27 = `
CREATE TABLE work_episodes (
  id TEXT PRIMARY KEY,
  agent_run_id TEXT NOT NULL UNIQUE,
  effort TEXT NOT NULL CHECK (effort IN (
    'conversational', 'focused_check', 'operational_assessment',
    'incident_investigation', 'engineering_task'
  )),
  authority TEXT NOT NULL CHECK (authority IN (
    'read_only', 'repository_write', 'governed_operation'
  )),
  state TEXT NOT NULL CHECK (state IN (
    'acknowledged', 'planning', 'working', 'blocked', 'waiting_approval',
    'verifying', 'completed', 'failed', 'cancelled', 'superseded'
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
  FOREIGN KEY(agent_run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
);

CREATE INDEX work_episodes_state_idx
  ON work_episodes(state, progress_due_at, updated_at);

CREATE TABLE work_episode_progress (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  phase TEXT NOT NULL,
  summary TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(episode_id, sequence),
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
);

CREATE INDEX work_episode_progress_episode_idx
  ON work_episode_progress(episode_id, sequence);

INSERT INTO work_episodes (
  id, agent_run_id, effort, authority, state, objective,
  required_coverage_json, completion_criteria_json, phase, status, next_action,
  created_at, updated_at, completed_at
)
SELECT
  'episode_' || r.id,
  r.id,
  CASE
    WHEN r.mode = 'engineering_task' THEN 'engineering_task'
    WHEN r.mode = 'incident' THEN 'incident_investigation'
    ELSE 'focused_check'
  END,
  CASE WHEN r.mode = 'engineering_task' THEN 'repository_write' ELSE 'read_only' END,
  CASE
    WHEN r.state IN ('pending', 'preparing') THEN 'acknowledged'
    WHEN r.state = 'running' THEN 'working'
    WHEN r.state IN ('applying', 'finalizing') THEN 'verifying'
    WHEN r.state = 'completed' THEN 'completed'
    WHEN r.state = 'failed' THEN 'failed'
    WHEN r.state = 'cancelled' THEN 'cancelled'
    ELSE 'superseded'
  END,
  c.title,
  '[]',
  '[]',
  CASE
    WHEN r.state = 'running' THEN 'investigating'
    WHEN r.state IN ('applying', 'finalizing') THEN 'delivering'
    WHEN r.state IN ('completed', 'failed', 'cancelled', 'superseded') THEN 'finished'
    ELSE 'accepted'
  END,
  CASE
    WHEN r.state = 'running' THEN 'Investigating'
    WHEN r.state IN ('applying', 'finalizing') THEN 'Preparing the result'
    WHEN r.state = 'completed' THEN 'Completed'
    WHEN r.state = 'failed' THEN COALESCE(NULLIF(r.last_error, ''), 'Needs operator attention')
    WHEN r.state IN ('cancelled', 'superseded') THEN 'Cancelled'
    ELSE 'Accepted'
  END,
  CASE
    WHEN r.state = 'running' THEN 'Complete the evidence plan'
    WHEN r.state IN ('applying', 'finalizing') THEN 'Deliver the result'
    WHEN r.state = 'failed' THEN 'Review the blocker or retry'
    ELSE 'Plan the work'
  END,
  r.created_at,
  r.updated_at,
  r.completed_at
FROM agent_runs AS r
JOIN commitments AS c ON c.agent_run_id = r.id;
`

const schemaV28 = `
CREATE TABLE publication_followups (
  incident_id TEXT PRIMARY KEY,
  pr_state TEXT NOT NULL DEFAULT 'open',
  checks_state TEXT NOT NULL DEFAULT 'unknown',
  merge_sha TEXT NOT NULL DEFAULT '',
  merged_at TEXT,
  next_check_at TEXT NOT NULL,
  failure_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  last_event_key TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(incident_id) REFERENCES publications(incident_id) ON DELETE CASCADE
);

CREATE INDEX publication_followups_due_idx
  ON publication_followups(next_check_at, updated_at);

CREATE TABLE publication_lifecycle_events (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  state TEXT NOT NULL,
  summary TEXT NOT NULL,
  source_channel_id TEXT NOT NULL DEFAULT '',
  source_message_ts TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  FOREIGN KEY(incident_id) REFERENCES publications(incident_id) ON DELETE CASCADE
);

CREATE INDEX publication_lifecycle_events_incident_idx
  ON publication_lifecycle_events(incident_id, created_at);

INSERT INTO publication_followups (
  incident_id, next_check_at, last_event_key, created_at, updated_at
)
SELECT
  incident_id,
  updated_at,
  CASE
    WHEN incident_id = (
      SELECT incident_id
      FROM publications
      WHERE state = 'published'
      ORDER BY published_at DESC, updated_at DESC, incident_id DESC
      LIMIT 1
    ) THEN ''
    ELSE 'baseline'
  END,
  updated_at,
  updated_at
FROM publications
WHERE state = 'published';
`

const schemaV29 = `
ALTER TABLE scheduled_tasks ADD COLUMN delivery_channel_id TEXT NOT NULL DEFAULT '';
UPDATE scheduled_tasks
SET delivery_channel_id = channel_id
WHERE delivery_channel_id = '';
`

const schemaV30 = `
ALTER TABLE evidence ADD COLUMN claim_id TEXT NOT NULL DEFAULT '';
ALTER TABLE evidence ADD COLUMN relation TEXT NOT NULL DEFAULT 'supports';
ALTER TABLE evidence ADD COLUMN dimensions_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE evidence ADD COLUMN valid_until TEXT;
ALTER TABLE coverage ADD COLUMN claim_ids_json TEXT NOT NULL DEFAULT '[]';

CREATE TABLE claim_assessments (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  claim_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'supported', 'contradicted', 'mixed', 'unknown', 'not_applicable'
  )),
  confidence TEXT NOT NULL DEFAULT '',
  evidence_ids_json TEXT NOT NULL DEFAULT '[]',
  contradiction_ids_json TEXT NOT NULL DEFAULT '[]',
  detail TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL,
  UNIQUE(episode_id, claim_id),
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
);

CREATE INDEX claim_assessments_episode_idx
  ON claim_assessments(episode_id, claim_id);
`

const schemaV31 = `
ALTER TABLE work_episodes ADD COLUMN event_sequence INTEGER NOT NULL DEFAULT 0;

CREATE TABLE work_episode_events (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  kind TEXT NOT NULL,
  actor TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  payload_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  UNIQUE(episode_id, sequence),
  UNIQUE(episode_id, idempotency_key),
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
);

CREATE INDEX work_episode_events_episode_idx
  ON work_episode_events(episode_id, sequence);

INSERT INTO work_episode_events (
  id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at
)
SELECT
  'episode_event_' || p.id,
  p.episode_id,
  p.sequence,
  CASE WHEN p.sequence = 1 THEN 'episode_created' ELSE 'progress_reported' END,
  'host',
  'legacy:' || p.id,
  json_object('phase', p.phase, 'summary', p.summary),
  p.created_at
FROM work_episode_progress AS p;

UPDATE work_episodes SET event_sequence = progress_sequence;
`

const schemaV32 = `
ALTER TABLE slack_deliveries ADD COLUMN sequence_key TEXT NOT NULL DEFAULT '';
ALTER TABLE slack_deliveries ADD COLUMN sequence_index INTEGER NOT NULL DEFAULT 0;

UPDATE slack_deliveries
SET
  sequence_key = substr(id, 1, length(id) - 9),
  sequence_index = CAST(substr(id, length(id) - 2, 3) AS INTEGER)
WHERE substr(id, length(id) - 8, 6) = '_part_'
  AND substr(id, length(id) - 2, 3) GLOB '[0-9][0-9][0-9]';

CREATE INDEX slack_delivery_sequence_idx
  ON slack_deliveries(sequence_key, sequence_index, state)
  WHERE sequence_key != '';
`

const schemaV33 = `
ALTER TABLE work_episodes ADD COLUMN activity TEXT NOT NULL DEFAULT 'investigating';

UPDATE work_episodes
SET activity = CASE
  WHEN effort = 'engineering_task' THEN 'engineering'
  WHEN authority = 'governed_operation' THEN 'operating'
  ELSE 'investigating'
END;
`

const schemaV34 = `
ALTER TABLE evidence ADD COLUMN source_id TEXT NOT NULL DEFAULT '';
`

const schemaV35 = `
ALTER TABLE evidence ADD COLUMN scope_note TEXT NOT NULL DEFAULT '';
`

const schemaV36 = `
ALTER TABLE evidence ADD COLUMN health_effect TEXT NOT NULL DEFAULT 'none';
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
	schemaV11,
	schemaV12,
	schemaV13,
	schemaV14,
	schemaV15,
	schemaV16,
	schemaV17,
	schemaV18,
	schemaV19,
	schemaV20,
	schemaV21,
	schemaV22,
	schemaV23,
	schemaV24,
	schemaV25,
	schemaV26,
	schemaV27,
	schemaV28,
	schemaV29,
	schemaV30,
	schemaV31,
	schemaV32,
	schemaV33,
	schemaV34,
	schemaV35,
	schemaV36,
}
