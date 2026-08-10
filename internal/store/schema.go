package store

const currentSchemaVersion = 52

const connectionPragmas = `
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
`

const persistentPragmas = `
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
`

// baselineSchema is the complete current schema. Responder collapsed its first
// forty incremental migrations into this single statement once every deployed
// database had reached version 39: replaying four decades of table rebuilds on
// every fresh install cost startup time and made the live shape of a table
// impossible to read without mentally replaying the chain.
//
// Adding a change: append a schemaVN constant and its migrations entry, and
// leave this baseline alone. Regenerate it only when every deployed database
// has passed the new minimumUpgradableVersion.
const baselineSchema = `
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

CREATE TABLE agent_runs (
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
  completed_at TEXT, episode_id TEXT NOT NULL DEFAULT '', attempt_id TEXT NOT NULL DEFAULT '', attempt_number INTEGER NOT NULL DEFAULT 0,
  UNIQUE(source_kind, source_id),
  FOREIGN KEY(incident_id) REFERENCES incidents(id) ON DELETE CASCADE
);

CREATE INDEX agent_runs_conversation_idx
  ON agent_runs(conversation_key, state, created_at);

CREATE INDEX agent_runs_episode_idx
  ON agent_runs(episode_id, attempt_number, created_at);

CREATE INDEX agent_runs_session_idx
  ON agent_runs(session_id, state, coop_event_sequence);

CREATE INDEX agent_runs_work_idx
  ON agent_runs(state, next_attempt_at, created_at);

CREATE TABLE audit_events (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  actor_id TEXT NOT NULL DEFAULT '',
  object_id TEXT NOT NULL DEFAULT '',
  outcome TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);

CREATE INDEX audit_incident_idx ON audit_events(incident_id, created_at);

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

CREATE TABLE channel_memories (
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
, coop_event_sequence INTEGER NOT NULL DEFAULT 0);

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

CREATE TABLE commitments (
  agent_run_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  FOREIGN KEY(agent_run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
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
, response_thread_ts TEXT NOT NULL DEFAULT '', thread_roots_json TEXT NOT NULL DEFAULT '[]');

CREATE UNIQUE INDEX configuration_sessions_active_channel_idx
  ON configuration_sessions(channel_id)
  WHERE status IN ('asking', 'confirming');

CREATE INDEX configuration_sessions_expiry_idx
  ON configuration_sessions(status, expires_at);

CREATE TABLE context_manifest_refs (
  id TEXT PRIMARY KEY,
  manifest_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  content_digest TEXT NOT NULL DEFAULT '',
  source_revision TEXT NOT NULL DEFAULT '',
  visibility TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  omitted_reason TEXT NOT NULL DEFAULT '',
  metadata_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE(manifest_id, ordinal),
  FOREIGN KEY(manifest_id) REFERENCES context_manifests(id) ON DELETE CASCADE
);

CREATE INDEX context_manifest_refs_source_idx
  ON context_manifest_refs(source_ref, source_revision);

CREATE TABLE context_manifests (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  parent_manifest_id TEXT NOT NULL DEFAULT '',
  version INTEGER NOT NULL,
  prompt_version TEXT NOT NULL DEFAULT '',
  contract_version TEXT NOT NULL DEFAULT '',
  tool_schema_version TEXT NOT NULL DEFAULT '',
  preset TEXT NOT NULL DEFAULT '',
  provider TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  reasoning_effort TEXT NOT NULL DEFAULT '',
  omissions_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  UNIQUE(episode_id, version),
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE,
  FOREIGN KEY(attempt_id) REFERENCES episode_attempts(id) ON DELETE CASCADE
);

CREATE TABLE conversation_memories (
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  repository TEXT NOT NULL,
  last_message_ts TEXT NOT NULL DEFAULT '',
  state_json TEXT NOT NULL DEFAULT '{}',
  updated_at TEXT NOT NULL, last_recalled_at TEXT, recall_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(channel_id, thread_ts)
);

CREATE INDEX conversation_memories_recent_idx
  ON conversation_memories(updated_at DESC);

CREATE INDEX conversation_memories_repository_idx
  ON conversation_memories(repository, updated_at DESC);

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

CREATE TABLE coop_cleanup (
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

CREATE INDEX coop_cleanup_work_idx
  ON coop_cleanup(state, next_attempt_at, eligible_at);

CREATE TABLE coverage (
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
, claim_ids_json TEXT NOT NULL DEFAULT '[]');

CREATE INDEX coverage_channel_idx ON coverage(channel_id, created_at);

CREATE INDEX coverage_incident_idx ON coverage(incident_id, created_at);

CREATE UNIQUE INDEX coverage_source_once_idx
  ON coverage(source_input, layer) WHERE source_input != '';

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

CREATE INDEX emisar_approvals_channel_idx
  ON emisar_approvals(channel_id, expires_at);

CREATE INDEX emisar_approvals_incident_idx
  ON emisar_approvals(incident_id, expires_at);

CREATE INDEX emisar_approvals_monitor_idx
  ON emisar_approvals(continuation_queued, next_check_at, created_at);

CREATE UNIQUE INDEX emisar_approvals_source_once_idx
  ON emisar_approvals(source_input, request_id);

CREATE TABLE episode_attempts (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  agent_run_id TEXT NOT NULL UNIQUE,
  attempt_number INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN (
    'pending', 'leased', 'running', 'succeeded', 'failed', 'cancelled'
  )),
  failure_class TEXT NOT NULL DEFAULT '',
  failure_generation INTEGER NOT NULL DEFAULT 0,
  lease_owner TEXT NOT NULL DEFAULT '',
  fencing_token INTEGER NOT NULL DEFAULT 0,
  lease_expires_at TEXT,
  context_manifest_id TEXT NOT NULL DEFAULT '',
  started_at TEXT,
  completed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(episode_id, attempt_number),
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE,
  FOREIGN KEY(agent_run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
);

CREATE INDEX episode_attempts_episode_idx
  ON episode_attempts(episode_id, attempt_number);

CREATE INDEX episode_attempts_lease_idx
  ON episode_attempts(state, lease_expires_at, updated_at);

CREATE TABLE episode_goals (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  parent_goal_id TEXT NOT NULL DEFAULT '',
  prerequisite_goal_ids_json TEXT NOT NULL DEFAULT '[]',
  kind TEXT NOT NULL,
  requested_outcome TEXT NOT NULL,
  completion_contract TEXT NOT NULL,
  writable_repository TEXT NOT NULL DEFAULT '',
  read_only_repositories_json TEXT NOT NULL DEFAULT '[]',
  authority_requirement TEXT NOT NULL CHECK (authority_requirement IN (
    'read_only', 'repository_write', 'governed_operation'
  )),
  required INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL CHECK (state IN (
    'planned', 'ready', 'working', 'waiting', 'completed', 'blocked',
    'excluded', 'cancelled'
  )),
  blocker TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  completed_at TEXT,
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
);

CREATE INDEX episode_goals_episode_idx
  ON episode_goals(episode_id, state, created_at);

CREATE TABLE episode_wakeups (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  event_matcher_json BLOB NOT NULL DEFAULT '{}',
  due_at TEXT,
  poll_after TEXT,
  deadline TEXT,
  state TEXT NOT NULL CHECK (state IN (
    'pending', 'leased', 'resolved', 'expired', 'cancelled'
  )),
  last_observation_json BLOB NOT NULL DEFAULT '{}',
  lease_owner TEXT NOT NULL DEFAULT '',
  fencing_token INTEGER NOT NULL DEFAULT 0,
  lease_expires_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  resolved_at TEXT,
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
);

CREATE INDEX episode_wakeups_due_idx
  ON episode_wakeups(state, due_at, poll_after, deadline);

CREATE INDEX episode_wakeups_episode_idx
  ON episode_wakeups(episode_id, state, created_at);

CREATE TABLE evaluation_decisions (
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

CREATE INDEX evaluation_channel_idx
  ON evaluation_decisions(channel_id, created_at);

CREATE TABLE evidence (
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
, claim_id TEXT NOT NULL DEFAULT '', relation TEXT NOT NULL DEFAULT 'supports', dimensions_json TEXT NOT NULL DEFAULT '{}', valid_until TEXT, source_id TEXT NOT NULL DEFAULT '', scope_note TEXT NOT NULL DEFAULT '', health_effect TEXT NOT NULL DEFAULT 'none');

CREATE INDEX evidence_channel_idx ON evidence(channel_id, created_at);

CREATE INDEX evidence_incident_idx ON evidence(incident_id, created_at);

CREATE UNIQUE INDEX evidence_source_once_idx
  ON evidence(source_input, claim, source_name, target) WHERE source_input != '';

CREATE TABLE incidents (
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
, channel_state TEXT NOT NULL DEFAULT 'pending'
  CHECK (channel_state IN ('pending', 'active', 'archived', 'deleted', 'unreachable')), channel_state_changed_at TEXT, channel_checked_at TEXT, work_kind TEXT NOT NULL DEFAULT 'incident'
  CHECK (work_kind IN ('incident', 'engineering_task')), work_scope TEXT NOT NULL DEFAULT 'room'
  CHECK (work_scope IN ('room', 'thread')), origin_channel_id TEXT NOT NULL DEFAULT '', origin_thread_ts TEXT NOT NULL DEFAULT '');

CREATE INDEX incidents_channel_idx ON incidents(channel_id);

CREATE INDEX incidents_channel_lifecycle_idx
  ON incidents(channel_state, channel_checked_at, status);

CREATE INDEX incidents_conversation_idx
  ON incidents(work_scope, origin_channel_id, origin_thread_ts, status);

CREATE INDEX incidents_correlation_idx
  ON incidents(route, repository, correlation_key, updated_at);

CREATE UNIQUE INDEX incidents_manual_source_once_idx
  ON incidents(correlation_key) WHERE route = 'manual';

CREATE INDEX incidents_session_idx ON incidents(coop_session_id);

CREATE INDEX incidents_work_idx ON incidents(workflow, updated_at);

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
  updated_at TEXT NOT NULL, last_recalled_at TEXT, recall_count INTEGER NOT NULL DEFAULT 0, last_reviewed_at TEXT,
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

CREATE INDEX memory_expiry_idx ON memory_entries(expires_at);

CREATE INDEX memory_lookup_idx
  ON memory_entries(scope_kind, scope_key, visibility_kind, visibility_id, expires_at);

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

CREATE TABLE proposal_approvals (
  proposal_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  decision TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(proposal_id, actor_id),
  FOREIGN KEY(proposal_id) REFERENCES action_proposals(id)
);

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

CREATE TABLE publications (
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

CREATE INDEX publications_state_idx
  ON publications(state, updated_at);

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

CREATE INDEX responder_preferences_expiry_idx
  ON responder_preferences(expires_at);

CREATE INDEX responder_preferences_lookup_idx
  ON responder_preferences(scope_kind, scope_key, enabled, expires_at);

CREATE TABLE responder_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

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
  updated_at TEXT NOT NULL, episode_id TEXT NOT NULL DEFAULT '',
  PRIMARY KEY(task_id, scheduled_for),
  FOREIGN KEY(task_id) REFERENCES scheduled_tasks(id) ON DELETE CASCADE
);

CREATE INDEX scheduled_task_runs_episode_idx
  ON scheduled_task_runs(episode_id, outcome, updated_at);

CREATE UNIQUE INDEX scheduled_task_runs_input_once_idx
  ON scheduled_task_runs(source_input) WHERE source_input != '';

CREATE INDEX scheduled_task_runs_state_idx
  ON scheduled_task_runs(outcome, updated_at);

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
, delivery_channel_id TEXT NOT NULL DEFAULT '');

CREATE INDEX scheduled_tasks_channel_idx
  ON scheduled_tasks(channel_id, expires_at, updated_at DESC);

CREATE INDEX scheduled_tasks_due_idx
  ON scheduled_tasks(enabled, next_run_at, expires_at);

CREATE UNIQUE INDEX scheduled_tasks_source_once_idx
  ON scheduled_tasks(team_id, channel_id, source_ref);

CREATE TABLE schema_version (
  version INTEGER NOT NULL
);

CREATE TABLE signals (
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

CREATE INDEX signals_incident_idx ON signals(incident_id, status);

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
  updated_at TEXT NOT NULL, sequence_key TEXT NOT NULL DEFAULT '', sequence_index INTEGER NOT NULL DEFAULT 0, episode_id TEXT NOT NULL DEFAULT '', expected_episode_revision INTEGER NOT NULL DEFAULT 0, expected_destination_revision INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(incident_id) REFERENCES incidents(id) ON DELETE CASCADE
);

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

CREATE TABLE slack_inputs (
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
  updated_at TEXT NOT NULL, failure_count INTEGER NOT NULL DEFAULT 0, attachments_json BLOB NOT NULL DEFAULT '[]',
  UNIQUE(envelope_id)
);

CREATE UNIQUE INDEX slack_event_once_idx
  ON slack_inputs(event_id) WHERE event_id != '';

CREATE INDEX slack_work_idx
  ON slack_inputs(state, next_attempt_at, received_at);

CREATE TABLE slack_settings (
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

CREATE TABLE slack_status_generations (
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL,
  generation INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(channel_id, thread_ts)
);

CREATE TABLE standing_rule_runs (
  rule_id TEXT NOT NULL,
  source_input TEXT NOT NULL,
  event_id TEXT NOT NULL,
  outcome TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(rule_id, source_input),
  FOREIGN KEY(rule_id) REFERENCES standing_rules(id) ON DELETE CASCADE
);

CREATE INDEX standing_rule_runs_created_idx
  ON standing_rule_runs(created_at);

CREATE TABLE standing_rules (
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

CREATE INDEX standing_rules_channel_idx
  ON standing_rules(channel_id, enabled, expires_at);

CREATE INDEX standing_rules_expiry_idx ON standing_rules(expires_at);

CREATE TABLE timeline_events (
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

CREATE INDEX timeline_channel_idx
  ON timeline_events(channel_id, created_at);

CREATE INDEX timeline_incident_idx
  ON timeline_events(incident_id, created_at);

CREATE TABLE webhook_events (
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

CREATE INDEX webhook_work_idx
  ON webhook_events(state, next_attempt_at, received_at);

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
  completed_at TEXT, event_sequence INTEGER NOT NULL DEFAULT 0, activity TEXT NOT NULL DEFAULT 'investigating', lifecycle_state TEXT NOT NULL DEFAULT 'accepted', workspace_id TEXT NOT NULL DEFAULT '', parent_episode_id TEXT NOT NULL DEFAULT '', mode TEXT NOT NULL DEFAULT 'check', platform TEXT NOT NULL DEFAULT 'slack', channel_id TEXT NOT NULL DEFAULT '', thread_ts TEXT NOT NULL DEFAULT '', anchor_ts TEXT NOT NULL DEFAULT '', visibility TEXT NOT NULL DEFAULT 'channel', destination_channel_id TEXT NOT NULL DEFAULT '', destination_thread_ts TEXT NOT NULL DEFAULT '', destination_revision INTEGER NOT NULL DEFAULT 1, latest_attempt_id TEXT NOT NULL DEFAULT '', authority_snapshot_ref TEXT NOT NULL DEFAULT '',
  FOREIGN KEY(agent_run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
);

CREATE INDEX work_episodes_state_idx
  ON work_episodes(state, progress_due_at, updated_at);

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

CREATE INDEX work_items_conversation_idx
  ON work_items(conversation_key, state, lease_expires_at)
  WHERE conversation_key != '';

CREATE INDEX work_items_due_idx
  ON work_items(lane, state, available_at, priority, created_at);
`

// baselineSchemaVersion is the version baselineSchema produces directly.
const baselineSchemaVersion = 40

// minimumUpgradableVersion is the oldest database this binary can migrate.
// Older databases predate the baseline and no released binary ever produced
// them, so failing loudly beats silently applying a partial schema.
//
// Defined against releases, as of v0.1.0: the oldest supported release is
// v0.1.0, whose fresh installs are created at the version-40 baseline and
// whose upgrades were proven from 39 — the newest schema any pre-release
// deployment ever ran. Nothing older was ever published, so nothing older is
// a migration target. Raise this only when a release drops support for the
// databases an older release produced, and say which release in this comment:
// the error an operator sees names a boundary, and the boundary must have
// been published somewhere they could have read.
const minimumUpgradableVersion = 39

const schemaV40 = `
-- The episode effect ledger was built ahead of its callers and no live path
-- ever planned, leased, or completed an effect. Remove it rather than carry an
-- unused lease surface beside the work_items scheduler that does own delivery.
DROP INDEX IF EXISTS episode_effects_due_idx;
DROP INDEX IF EXISTS episode_effects_episode_idx;
DROP TABLE IF EXISTS episode_effects;
`

const schemaV42 = `
-- Commitments were keyed by the agent run that made them, and the projection
-- reached the episode through work_episodes.agent_run_id — which names the
-- ORIGINATING run. A commitment made by a replacement attempt therefore joined
-- to nothing and vanished from every "what are you working on" view, while
-- still sitting in the table. On the database this migration was written
-- against, 16 of 335 were invisible.
--
-- A commitment is a promise to a person about a unit of work, not about the
-- transport attempt that happened to carry it, so the episode is its real key.
-- Re-keying makes the disappearance structurally impossible rather than fixed.
CREATE TABLE commitments_by_episode (
  episode_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE
);

-- Earliest title wins: it is the promise as originally made, and a later
-- attempt restating it should not overwrite the words the operator saw first.
INSERT OR IGNORE INTO commitments_by_episode (episode_id, title)
SELECT r.episode_id, c.title
FROM commitments AS c
JOIN agent_runs AS r ON r.id = c.agent_run_id
WHERE r.episode_id != ''
ORDER BY r.created_at ASC;

DROP TABLE commitments;
ALTER TABLE commitments_by_episode RENAME TO commitments;
`

const schemaV43 = `
-- A standing assignment is how an operator grants scoped authority once instead
-- of confirming every action. It does not remove the confirmation Responder
-- relies on; it moves it earlier in time, which is the only way autonomous work
-- can keep the invariant that nothing acts without someone having said yes.
--
-- Every column here is a bound. change_class is an allowlist rather than free
-- text because free text means "Responder may change anything"; path_globs
-- narrows the repository because a repository is far too large a blast radius
-- to grant in one click; daily_budget and expires_at mean a forgotten
-- assignment decays instead of running forever.
CREATE TABLE standing_assignments (
  id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL,
  signal_pattern TEXT NOT NULL,
  repository TEXT NOT NULL,
  path_globs_json TEXT NOT NULL DEFAULT '[]',
  change_class TEXT NOT NULL CHECK (change_class IN (
    'dependency_upgrade', 'alert_threshold', 'flaky_test_quarantine',
    'observability', 'documentation'
  )),
  daily_budget INTEGER NOT NULL CHECK (daily_budget > 0 AND daily_budget <= 20),
  actor_id TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  confirmed_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX standing_assignments_channel_idx
  ON standing_assignments(channel_id, enabled, expires_at);

-- One row per action an assignment took. This serves two jobs that would
-- otherwise need separate bookkeeping: the unique constraint makes "one pull
-- request per issue" structural rather than a check someone has to remember,
-- and counting today's rows is the budget.
CREATE TABLE standing_assignment_actions (
  id TEXT PRIMARY KEY,
  assignment_id TEXT NOT NULL,
  correlation_key TEXT NOT NULL,
  episode_id TEXT NOT NULL DEFAULT '',
  outcome TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(assignment_id, correlation_key),
  FOREIGN KEY(assignment_id) REFERENCES standing_assignments(id) ON DELETE CASCADE
);

CREATE INDEX standing_assignment_actions_budget_idx
  ON standing_assignment_actions(assignment_id, created_at);
`

const schemaV44 = `
-- A correction is a regression fixture that writes itself: the host already
-- decided the model was wrong and said exactly why, which is a label no one had
-- to produce by hand. This table is the queue between that moment and the
-- corpus, because section 23.3 requires a human to review anything entering a
-- release gate — and because review is also what keeps the corpus from filling
-- with the same three mistakes.
--
-- expires_at is not housekeeping. A candidate nobody reviewed for a fortnight is
-- evidence about a prompt version that may no longer exist, and promoting it
-- later encodes a bug that was already fixed. Stale candidates must lapse rather
-- than wait forever.
CREATE TABLE fixture_candidates (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  capability TEXT NOT NULL DEFAULT '',
  correction_class TEXT NOT NULL,
  correction TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected', 'expired')),
  reviewed_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(episode_id, correction_class)
);

CREATE INDEX fixture_candidates_review_idx
  ON fixture_candidates(status, created_at);
`

// migrations maps a target schema version to the statement that reaches it
// from the version before. Versions at or below the baseline are absent
// because baselineSchema already produces them.
const schemaV41 = `
-- Product feedback lived in its own SQLite file beside the main database, which
-- put it outside the schema baseline, outside the verified pre-migration
-- backup, and outside every cross-table transaction. Feedback is durable
-- product state and belongs under the same guarantees as everything else.
CREATE TABLE feedback_items (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  message_ts TEXT NOT NULL DEFAULT '',
  target_message_ts TEXT NOT NULL DEFAULT '',
  user_id TEXT NOT NULL,
  source TEXT NOT NULL,
  category TEXT NOT NULL,
  sentiment TEXT NOT NULL,
  summary TEXT NOT NULL,
  details TEXT NOT NULL DEFAULT '',
  context_json BLOB NOT NULL,
  episode_id TEXT NOT NULL DEFAULT '',
  agent_run_id TEXT NOT NULL DEFAULT '',
  source_ref TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  resolved_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX feedback_items_workspace_status_updated
  ON feedback_items(workspace_id, status, updated_at DESC);
`

const schemaV45 = `
-- Schedule prompts can be much larger than Slack's interactive action value.
-- Keep the normalized proposal in SQLite and send Slack only this row's opaque
-- ID. Acceptance is an atomic pending -> accepted transition, so button retries
-- and conversational confirmations cannot create duplicate schedules.
CREATE TABLE schedule_proposals (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  thread_ts TEXT NOT NULL DEFAULT '',
  actor_id TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  task_json BLOB NOT NULL,
  replace_task_id TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'expired')),
  accepted_task_id TEXT NOT NULL DEFAULT '',
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(team_id, channel_id, source_ref)
);

CREATE INDEX schedule_proposals_conversation_idx
  ON schedule_proposals(team_id, channel_id, thread_ts, actor_id, status, created_at DESC);
`

var migrations = map[int]string{
	40: schemaV40,
	41: schemaV41,
	42: schemaV42,
	43: schemaV43,
	44: schemaV44,
	45: schemaV45,
	46: schemaV46,
	47: schemaV47,
	48: schemaV48,
	49: schemaV49,
	50: schemaV50,
	51: schemaV51,
	52: schemaV52,
}
