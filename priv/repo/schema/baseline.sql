-- The Ryker schema as of 2026-09-26, squashed from the 116 migrations that
-- built it (codebase wave 5). Generated with pg_dump --schema-only from a
-- database migrated through the full ladder; the default token rates the
-- ladder seeded follow the schema.

CREATE FUNCTION public.ryker_control_plane_notify() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_notify('ryker_control_plane', TG_TABLE_NAME);
  RETURN NULL;
END;
$$;

CREATE FUNCTION public.ryker_learning_roots(dependencies text) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
  WITH parsed AS (
    SELECT CASE WHEN pg_input_is_valid(dependencies, 'jsonb')
      THEN dependencies::jsonb ELSE 'null'::jsonb END AS value
  ), descriptors AS (
    SELECT d FROM parsed,
      LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(value) = 'array'
        THEN value ELSE '[null]'::jsonb END) d
  )
  SELECT d FROM descriptors WHERE NOT coalesce(d ? 'knowledge_id', false)
  UNION ALL
  SELECT s.receipt::jsonb
  FROM descriptors d
  LEFT JOIN LATERAL (
  SELECT v.knowledge_id, v.source_generation, v.version
  FROM "public"."conversation_knowledge_revisions" v
  WHERE d->>'kind' = 'knowledge_sources'
  AND jsonb_typeof(d) = 'object'
  AND jsonb_typeof(d->'generation') = 'number'
  AND jsonb_typeof(d->'through_version') = 'number'
  AND (SELECT count(*) FROM jsonb_object_keys(CASE WHEN jsonb_typeof(d) = 'object'
    THEN d ELSE '{}'::jsonb END)) = 4
  AND v.knowledge_id = CASE WHEN pg_input_is_valid(d->>'knowledge_id', 'uuid')
    THEN (d->>'knowledge_id')::uuid ELSE NULL END
  AND v.source_generation = CASE WHEN pg_input_is_valid(d->>'generation', 'bigint')
    THEN (d->>'generation')::bigint ELSE NULL END
  AND v.version = CASE WHEN pg_input_is_valid(d->>'through_version', 'bigint')
    THEN (d->>'through_version')::bigint ELSE NULL END

  OFFSET 0
) v ON true

  LEFT JOIN "public"."conversation_knowledge_sources" s
    ON s.knowledge_id = v.knowledge_id AND s.generation = v.source_generation
    AND s.introduced_version <= v.version
  WHERE coalesce(d ? 'knowledge_id', false)
$$;

CREATE TABLE public.admission_attempts (
    id uuid NOT NULL,
    input_id uuid NOT NULL,
    generation integer NOT NULL,
    policy text NOT NULL,
    policy_digest text NOT NULL,
    submission text,
    submission_fingerprint text,
    session_ref text,
    turn_ref text,
    execution_target text,
    phase text DEFAULT 'context_prepared'::text NOT NULL,
    milestones text DEFAULT '{}'::text NOT NULL,
    measurements text DEFAULT '{}'::text NOT NULL,
    response text,
    operational_pruned_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT admission_attempt_identity_valid CHECK (((generation > 0) AND ((octet_length(policy) >= 1) AND (octet_length(policy) <= 1024)) AND (policy_digest ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT admission_attempt_submission_valid CHECK ((((submission IS NULL) AND (submission_fingerprint IS NULL)) OR ((submission IS NOT NULL) AND (submission_fingerprint ~ '^[0-9a-f]{64}$'::text))))
);

CREATE TABLE public.control_plane_conversations (
    id uuid NOT NULL,
    environment_ref text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.conversation_knowledge (
    id uuid NOT NULL,
    scope_key text NOT NULL,
    topic_key text NOT NULL,
    transport text NOT NULL,
    workspace_ref text NOT NULL,
    conversation_ref text NOT NULL,
    repository_ref text,
    visibility text NOT NULL,
    state text NOT NULL,
    version bigint NOT NULL,
    source_generation bigint NOT NULL,
    source_dependencies text NOT NULL,
    source_input_id uuid NOT NULL,
    source_episode_id uuid,
    latest_source_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    anchor_keys text[] DEFAULT ARRAY[]::text[] NOT NULL,
    forgotten_at timestamp without time zone,
    CONSTRAINT knowledge_version_positive CHECK ((version > 0))
);

CREATE TABLE public.conversation_knowledge_revisions (
    knowledge_id uuid NOT NULL,
    version bigint NOT NULL,
    source_generation bigint NOT NULL,
    source_dependencies text NOT NULL,
    state text NOT NULL,
    source_input_id uuid NOT NULL,
    source_result_ref text NOT NULL,
    source_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);

CREATE TABLE public.conversation_knowledge_sources (
    knowledge_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    generation bigint NOT NULL,
    source_revision bigint NOT NULL,
    source_fingerprint text NOT NULL,
    source_note text,
    retained_at timestamp without time zone NOT NULL,
    introduced_version bigint NOT NULL,
    receipt_fingerprint text NOT NULL,
    receipt text NOT NULL,
    direct_support_version bigint,
    CONSTRAINT knowledge_receipt_json CHECK (pg_input_is_valid(receipt, 'jsonb'::text))
);

CREATE TABLE public.conversation_learning_batches (
    id uuid NOT NULL,
    scope_key text NOT NULL,
    transport text NOT NULL,
    conversation_ref text NOT NULL,
    repository_ref text,
    execution_mode text NOT NULL,
    policy text NOT NULL,
    policy_digest text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    start_count integer DEFAULT 0 NOT NULL,
    start_limit integer DEFAULT 3 NOT NULL,
    budget_version integer DEFAULT 0 NOT NULL,
    input_count integer NOT NULL,
    lease_ref uuid,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    heartbeat_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    error_code text,
    completed_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    rebuild_target_id uuid,
    rebuild_target_version bigint,
    rebuild_target_generation bigint,
    rebuild_selection text,
    CONSTRAINT learning_batch_state_valid CHECK (((status = ANY (ARRAY['queued'::text, 'running'::text, 'applied'::text, 'no_change'::text, 'deferred'::text, 'superseded'::text])) AND (execution_mode = ANY (ARRAY['live'::text, 'shadow'::text])) AND (budget_version >= 0) AND (start_limit >= 1) AND ((start_count >= 0) AND (start_count <= start_limit)) AND ((input_count >= 1) AND (input_count <= 16)) AND (((status = 'running'::text) AND (lease_ref IS NOT NULL) AND (lease_owner IS NOT NULL) AND (lease_expires_at IS NOT NULL)) OR ((status <> 'running'::text) AND (lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL))))),
    CONSTRAINT learning_rebuild_target_valid CHECK ((((rebuild_target_id IS NULL) AND (rebuild_target_version IS NULL) AND (rebuild_target_generation IS NULL) AND (rebuild_selection IS NULL)) OR ((rebuild_target_id IS NOT NULL) AND (rebuild_target_version IS NOT NULL) AND (rebuild_target_version > 0) AND (rebuild_target_generation IS NOT NULL) AND (rebuild_target_generation > 0) AND (rebuild_selection IS NOT NULL))))
);

CREATE TABLE public.conversation_learning_inputs (
    input_id uuid NOT NULL,
    batch_id uuid NOT NULL,
    terminal_reason text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.conversation_learning_runs (
    id uuid NOT NULL,
    batch_key text NOT NULL,
    generation bigint NOT NULL,
    status text NOT NULL,
    inputs text NOT NULL,
    source_dependencies text NOT NULL,
    knowledge text NOT NULL,
    omissions text NOT NULL,
    policy text NOT NULL,
    policy_digest text NOT NULL,
    prompt text,
    prompt_sha256 text NOT NULL,
    output_schema text NOT NULL,
    result text,
    result_sha256 text,
    producer text DEFAULT '{}'::text NOT NULL,
    error_code text,
    applied_at timestamp without time zone,
    pruned_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    match_refs text DEFAULT '[]'::text NOT NULL,
    batch_id uuid,
    started_at timestamp without time zone,
    submit_revision bigint,
    coop_turn_id text,
    candidate_attempt integer,
    validation_receipt text,
    stop_receipt text,
    remote_stopped_at timestamp without time zone,
    reconcile_attempt_count integer DEFAULT 0 NOT NULL,
    rebuild text,
    batch_budget_version integer DEFAULT 0 NOT NULL,
    CONSTRAINT conversation_learning_status_valid CHECK (((status = ANY (ARRAY['prepared'::text, 'responded'::text, 'applied'::text, 'stale'::text, 'rejected'::text])) AND (generation > 0))),
    CONSTRAINT learning_reconcile_count_valid CHECK ((reconcile_attempt_count >= 0)),
    CONSTRAINT learning_remote_stop_proven CHECK (((remote_stopped_at IS NULL) = (stop_receipt IS NULL)))
);

CREATE TABLE public.conversation_observations (
    id uuid NOT NULL,
    identity_key text NOT NULL,
    transport text NOT NULL,
    workspace_ref text NOT NULL,
    conversation_ref text NOT NULL,
    thread_ref text,
    repository_ref text,
    visibility text NOT NULL,
    source_input_id uuid NOT NULL,
    source_episode_id uuid,
    source_message_ref text NOT NULL,
    source_result_ref text,
    source_fingerprint text NOT NULL,
    actor_ref text NOT NULL,
    execution_mode text NOT NULL,
    revision bigint NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    note text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    source_dependencies text,
    forgotten_at timestamp without time zone,
    CONSTRAINT conversation_observations_revision_positive CHECK ((revision > 0))
);

CREATE TABLE public.conversation_rollups (
    id uuid NOT NULL,
    ref text NOT NULL,
    workspace_ref text NOT NULL,
    scope_kind text NOT NULL,
    scope_ref text NOT NULL,
    repository_ref text,
    visibility text NOT NULL,
    period_start timestamp without time zone NOT NULL,
    period_end timestamp without time zone NOT NULL,
    state text NOT NULL,
    state_fingerprint text NOT NULL,
    source_refs text NOT NULL,
    source_scopes text NOT NULL,
    source_count bigint NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    recall_count bigint DEFAULT 0 NOT NULL,
    last_recalled_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    source_dependencies text DEFAULT '[]'::text,
    CONSTRAINT conversation_rollup_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 1024)) AND (scope_kind = ANY (ARRAY['conversation'::text, 'repository'::text])) AND ((char_length(scope_ref) >= 1) AND (char_length(scope_ref) <= 1024)) AND ((repository_ref IS NULL) OR ((char_length(repository_ref) >= 1) AND (char_length(repository_ref) <= 1024))) AND (visibility = ANY (ARRAY['public'::text, 'private'::text, 'direct'::text, 'conversation'::text])) AND (period_end >= period_start) AND (expires_at > period_end) AND ((octet_length(state) >= 2) AND (octet_length(state) <= 32768)) AND (char_length(state_fingerprint) = 64) AND ((octet_length(source_refs) >= 2) AND (octet_length(source_refs) <= 32768)) AND ((octet_length(source_scopes) >= 2) AND (octet_length(source_scopes) <= 8388608)) AND (source_count > 0) AND (recall_count >= 0) AND (((scope_kind = 'repository'::text) AND (repository_ref = scope_ref) AND (visibility = 'public'::text)) OR (scope_kind = 'conversation'::text))))
);

CREATE TABLE public.conversation_summaries (
    id uuid NOT NULL,
    ref text NOT NULL,
    identity_key text NOT NULL,
    transport text NOT NULL,
    workspace_ref text NOT NULL,
    conversation_ref text NOT NULL,
    thread_ref text,
    repository_ref text,
    visibility text NOT NULL,
    state text NOT NULL,
    state_fingerprint text NOT NULL,
    source_episode_id uuid,
    source_turn_id uuid,
    source_result_ref text NOT NULL,
    source_message_ref text,
    recall_count bigint DEFAULT 0 NOT NULL,
    last_recalled_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    source_dependencies text DEFAULT '[]'::text,
    compaction_error_code text,
    compaction_retry_at timestamp without time zone,
    CONSTRAINT conversation_summary_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND (char_length(identity_key) = 64) AND ((char_length(transport) >= 1) AND (char_length(transport) <= 64)) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 1024)) AND ((char_length(conversation_ref) >= 1) AND (char_length(conversation_ref) <= 1024)) AND ((thread_ref IS NULL) OR ((char_length(thread_ref) >= 1) AND (char_length(thread_ref) <= 1024))) AND ((repository_ref IS NULL) OR ((char_length(repository_ref) >= 1) AND (char_length(repository_ref) <= 1024))) AND (visibility = ANY (ARRAY['public'::text, 'private'::text, 'direct'::text, 'conversation'::text])) AND ((octet_length(state) >= 2) AND (octet_length(state) <= 32768)) AND (char_length(state_fingerprint) = 64) AND ((char_length(source_result_ref) >= 1) AND (char_length(source_result_ref) <= 1024)) AND ((source_message_ref IS NULL) OR ((char_length(source_message_ref) >= 1) AND (char_length(source_message_ref) <= 1024))) AND (recall_count >= 0)))
);

CREATE TABLE public.conversation_summary_drafts (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    state text NOT NULL,
    state_fingerprint text NOT NULL,
    candidate_sha256 text,
    candidate_attempt bigint,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT conversation_summary_draft_valid CHECK (((revision > 0) AND ((octet_length(state) >= 2) AND (octet_length(state) <= 32768)) AND (char_length(state_fingerprint) = 64) AND (((candidate_sha256 IS NULL) AND (candidate_attempt IS NULL)) OR ((char_length(candidate_sha256) = 64) AND (candidate_attempt > 0)))))
);

CREATE TABLE public.coop_session_evidence (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    episode_id uuid,
    coop_session_id text NOT NULL,
    worker_id text NOT NULL,
    placement_generation bigint NOT NULL,
    evidence_version integer NOT NULL,
    content_fingerprint text NOT NULL,
    document text NOT NULL,
    session_revision bigint NOT NULL,
    session_state text NOT NULL,
    network_mode text NOT NULL,
    task_status text NOT NULL,
    first_captured_at timestamp without time zone NOT NULL,
    last_captured_at timestamp without time zone NOT NULL,
    capture_count bigint DEFAULT 1 NOT NULL,
    CONSTRAINT coop_session_evidence_valid CHECK ((((char_length(coop_session_id) >= 1) AND (char_length(coop_session_id) <= 1024)) AND ((char_length(worker_id) >= 1) AND (char_length(worker_id) <= 256)) AND (placement_generation > 0) AND (evidence_version = 1) AND (char_length(content_fingerprint) = 64) AND ((octet_length(document) >= 2) AND (octet_length(document) <= 524288)) AND (jsonb_typeof((document)::jsonb) = 'object'::text) AND (session_revision > 0) AND (session_state = ANY (ARRAY['open'::text, 'exhausted'::text, 'closed'::text, 'discarded'::text])) AND (network_mode = ANY (ARRAY['open'::text, 'none'::text, 'filtered'::text])) AND (task_status = ANY (ARRAY['bound'::text, 'unbound'::text, 'unavailable'::text])) AND (capture_count > 0) AND (last_captured_at >= first_captured_at)))
);

CREATE TABLE public.coop_session_placements (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    episode_id uuid,
    worker_id text NOT NULL,
    generation bigint NOT NULL,
    lease_ref text NOT NULL,
    lease_expires_at timestamp without time zone NOT NULL,
    state text DEFAULT 'assigning'::text NOT NULL,
    requirements text NOT NULL,
    requirements_fingerprint text NOT NULL,
    last_command_id uuid,
    last_acked_event_sequence bigint DEFAULT 0 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    last_acked_session_event_sequence bigint DEFAULT 0 CONSTRAINT coop_session_placements_last_acked_session_event_seque_not_null NOT NULL,
    CONSTRAINT coop_session_placement_identity_valid CHECK (((generation > 0) AND ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 256)) AND (state = ANY (ARRAY['assigning'::text, 'active'::text, 'draining'::text, 'revoking'::text, 'replaced'::text, 'retired'::text])) AND (jsonb_typeof((requirements)::jsonb) = 'object'::text) AND (octet_length(requirements) <= 131072) AND (char_length(requirements_fingerprint) = 64) AND (last_acked_event_sequence >= 0))),
    CONSTRAINT coop_session_placement_session_event_cursor_valid CHECK ((last_acked_session_event_sequence >= 0))
);

CREATE TABLE public.coop_worker_certificates (
    sha256 text NOT NULL,
    worker_id text NOT NULL,
    enrollment_token_id uuid,
    serial_number text NOT NULL,
    source text NOT NULL,
    issued_by text NOT NULL,
    not_before timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    revoked_at timestamp without time zone,
    revoked_by text,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_certificate_valid CHECK (((sha256 ~ '^[0-9a-f]{64}$'::text) AND ((char_length(serial_number) >= 1) AND (char_length(serial_number) <= 64)) AND (source = ANY (ARRAY['enrollment'::text, 'renewal'::text, 'manual'::text])) AND ((char_length(issued_by) >= 1) AND (char_length(issued_by) <= 256)) AND (expires_at > not_before) AND (((revoked_at IS NULL) AND (revoked_by IS NULL)) OR ((revoked_at IS NOT NULL) AND ((char_length(revoked_by) >= 1) AND (char_length(revoked_by) <= 256))))))
);

CREATE TABLE public.coop_worker_commands (
    id uuid NOT NULL,
    placement_id uuid NOT NULL,
    worker_id text NOT NULL,
    session_id uuid NOT NULL,
    placement_generation bigint NOT NULL,
    kind text NOT NULL,
    command_version bigint DEFAULT 1 NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    idempotency_key text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    operation_key text,
    result text,
    error text,
    result_fingerprint text,
    delivered_at timestamp without time zone,
    acknowledged_at timestamp without time zone,
    completed_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_command_identity_valid CHECK (((placement_generation > 0) AND (command_version = 1) AND (kind = ANY (ARRAY['ensure_workspace'::text, 'create_session'::text, 'get_session'::text, 'get_session_evidence'::text, 'submit_turn'::text, 'get_turn'::text, 'get_output_artifact'::text, 'get_changes'::text, 'get_changes_page'::text, 'run_review'::text, 'plan_discard'::text, 'discard_session'::text, 'get_review_patch'::text, 'validate_candidate'::text, 'cancel_turn'::text, 'fence_operation'::text, 'checkpoint_workspace'::text, 'close_session'::text, 'reconcile_operation'::text])) AND (char_length(payload_fingerprint) = 64) AND ((char_length(idempotency_key) >= 1) AND (char_length(idempotency_key) <= 512)) AND (status = ANY (ARRAY['queued'::text, 'delivered'::text, 'acknowledged'::text, 'succeeded'::text, 'failed'::text, 'uncertain'::text])))),
    CONSTRAINT coop_worker_command_result_valid CHECK ((((status = ANY (ARRAY['queued'::text, 'delivered'::text, 'acknowledged'::text])) AND (operation_key IS NULL) AND (result IS NULL) AND (error IS NULL) AND (result_fingerprint IS NULL) AND (completed_at IS NULL)) OR ((status = 'succeeded'::text) AND ((char_length(operation_key) >= 1) AND (char_length(operation_key) <= 512)) AND (result IS NOT NULL) AND (error IS NULL) AND (char_length(result_fingerprint) = 64) AND (completed_at IS NOT NULL)) OR ((status = ANY (ARRAY['failed'::text, 'uncertain'::text])) AND ((char_length(operation_key) >= 1) AND (char_length(operation_key) <= 512)) AND (result IS NULL) AND (error IS NOT NULL) AND (char_length(result_fingerprint) = 64) AND (completed_at IS NOT NULL))))
);

CREATE TABLE public.coop_worker_enrollment_tokens (
    id uuid NOT NULL,
    worker_id text NOT NULL,
    workspace_ref text NOT NULL,
    operator_ref text NOT NULL,
    token_sha256 text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    consumed_at timestamp without time zone,
    certificate_sha256 text,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_enrollment_token_valid CHECK (((char_length(worker_id) >= 1) AND (char_length(worker_id) <= 256) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(operator_ref) >= 1) AND (char_length(operator_ref) <= 256)) AND (token_sha256 ~ '^[0-9a-f]{64}$'::text) AND ((certificate_sha256 IS NULL) OR (certificate_sha256 ~ '^[0-9a-f]{64}$'::text)) AND (((consumed_at IS NULL) AND (certificate_sha256 IS NULL)) OR ((consumed_at IS NOT NULL) AND (certificate_sha256 IS NOT NULL)))))
);

CREATE TABLE public.coop_worker_events (
    id bigint NOT NULL,
    placement_id uuid NOT NULL,
    worker_id text NOT NULL,
    session_id uuid NOT NULL,
    placement_generation bigint NOT NULL,
    sequence bigint NOT NULL,
    kind text NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_event_identity_valid CHECK (((placement_generation > 0) AND (sequence > 0) AND (kind = ANY (ARRAY['operation'::text, 'session'::text, 'turn'::text, 'candidate'::text, 'validation'::text, 'workspace'::text, 'checkpoint'::text, 'capacity'::text, 'session_event'::text])) AND (char_length(payload_fingerprint) = 64)))
);

CREATE SEQUENCE public.coop_worker_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.coop_worker_events_id_seq OWNED BY public.coop_worker_events.id;

CREATE TABLE public.coop_worker_output_transfers (
    id uuid NOT NULL,
    command_id uuid NOT NULL,
    worker_id text NOT NULL,
    artifact_ref text NOT NULL,
    name text NOT NULL,
    media_type text NOT NULL,
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    data bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_output_transfer_identity_valid CHECK (((char_length(artifact_ref) >= 1) AND (char_length(artifact_ref) <= 256) AND (artifact_ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND ((char_length(name) >= 1) AND (char_length(name) <= 255)) AND (media_type = ANY (ARRAY['image/png'::text, 'image/jpeg'::text, 'image/webp'::text, 'image/gif'::text])) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 8388608)) AND (octet_length(data) = byte_size)))
);

CREATE TABLE public.coop_worker_review_patch_transfers (
    id uuid NOT NULL,
    command_id uuid NOT NULL,
    worker_id text NOT NULL,
    artifact_id text NOT NULL,
    sha256 text NOT NULL,
    byte_size bigint NOT NULL,
    data bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_review_patch_identity_valid CHECK (((char_length(artifact_id) >= 1) AND (char_length(artifact_id) <= 256) AND (artifact_id ~ '^[A-Za-z0-9_.:-]+$'::text) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 67108864)) AND (octet_length(data) = byte_size)))
);

CREATE TABLE public.coop_worker_workspace_checkpoints (
    id uuid NOT NULL,
    command_id uuid NOT NULL,
    worker_id text NOT NULL,
    checkpoint_ref text NOT NULL,
    session_ref text NOT NULL,
    placement_generation bigint NOT NULL,
    repository_ref text NOT NULL,
    descriptor text NOT NULL,
    bundle_sha256 text NOT NULL,
    bundle_byte_size bigint NOT NULL,
    encryption_key_sha256 text CONSTRAINT coop_worker_workspace_checkpoint_encryption_key_sha256_not_null NOT NULL,
    encryption_nonce bytea NOT NULL,
    encryption_tag bytea NOT NULL,
    ciphertext bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_workspace_checkpoint_identity_valid CHECK (((char_length(checkpoint_ref) >= 1) AND (char_length(checkpoint_ref) <= 256) AND (checkpoint_ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND ((char_length(session_ref) >= 1) AND (char_length(session_ref) <= 256)) AND (session_ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND (placement_generation > 0) AND ((char_length(repository_ref) >= 1) AND (char_length(repository_ref) <= 256)) AND (repository_ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND (jsonb_typeof((descriptor)::jsonb) = 'object'::text) AND ((octet_length(descriptor) >= 1) AND (octet_length(descriptor) <= 1048576)) AND (bundle_sha256 ~ '^[0-9a-f]{64}$'::text) AND ((bundle_byte_size >= 1) AND (bundle_byte_size <= 67108864)) AND (encryption_key_sha256 ~ '^[0-9a-f]{64}$'::text) AND (octet_length(encryption_nonce) = 12) AND (octet_length(encryption_tag) = 16) AND (octet_length(ciphertext) = bundle_byte_size)))
);

CREATE TABLE public.coop_workers (
    id text NOT NULL,
    workspace_ref text NOT NULL,
    certificate_sha256 text NOT NULL,
    protocol_version text,
    build_version text,
    clock_at timestamp without time zone,
    sandbox_digest text,
    policy_digests text DEFAULT '{}'::text NOT NULL,
    repositories text DEFAULT '[]'::text NOT NULL,
    capabilities text DEFAULT '[]'::text NOT NULL,
    capacity text DEFAULT '{}'::text NOT NULL,
    state text DEFAULT 'offline'::text NOT NULL,
    last_seen_at timestamp without time zone,
    drain_requested_at timestamp without time zone,
    drain_requested_by text,
    revoked_at timestamp without time zone,
    revoked_by text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    policy_authority_digests text DEFAULT '{}'::text NOT NULL,
    storage text,
    storage_reclaimed_bytes bigint DEFAULT 0 NOT NULL,
    CONSTRAINT coop_worker_documents_valid CHECK (((jsonb_typeof((policy_digests)::jsonb) = 'object'::text) AND (jsonb_typeof((policy_authority_digests)::jsonb) = 'object'::text) AND (jsonb_typeof((repositories)::jsonb) = 'array'::text) AND (jsonb_typeof((capabilities)::jsonb) = 'array'::text) AND (jsonb_typeof((capacity)::jsonb) = 'object'::text) AND (octet_length(policy_digests) <= 131072) AND (octet_length(policy_authority_digests) <= 131072) AND (octet_length(repositories) <= 131072) AND (octet_length(capabilities) <= 131072) AND (octet_length(capacity) <= 131072))),
    CONSTRAINT coop_worker_identity_valid CHECK (((char_length(id) >= 1) AND (char_length(id) <= 256) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND (certificate_sha256 ~ '^[0-9a-f]{64}$'::text) AND (state = ANY (ARRAY['offline'::text, 'eligible'::text, 'busy'::text, 'draining'::text, 'needs_auth'::text, 'revoked'::text])) AND ((protocol_version IS NULL) OR ((char_length(protocol_version) >= 1) AND (char_length(protocol_version) <= 64))) AND ((build_version IS NULL) OR ((char_length(build_version) >= 1) AND (char_length(build_version) <= 128))) AND ((sandbox_digest IS NULL) OR (sandbox_digest ~ '^[0-9a-f]{64}$'::text)) AND (((drain_requested_at IS NULL) AND (drain_requested_by IS NULL)) OR ((drain_requested_at IS NOT NULL) AND ((char_length(drain_requested_by) >= 1) AND (char_length(drain_requested_by) <= 256)))) AND (((state <> 'revoked'::text) AND (revoked_at IS NULL) AND (revoked_by IS NULL)) OR ((state = 'revoked'::text) AND (revoked_at IS NOT NULL) AND ((char_length(revoked_by) >= 1) AND (char_length(revoked_by) <= 256)))))),
    CONSTRAINT coop_worker_storage_valid CHECK (((storage_reclaimed_bytes >= 0) AND ((storage IS NULL) OR ((octet_length(storage) <= 4096) AND (jsonb_typeof((storage)::jsonb) = 'object'::text) AND ((((storage)::jsonb ->> 'version'::text))::integer = 1) AND (((storage)::jsonb ->> 'allocation'::text) = ANY (ARRAY['open'::text, 'refused'::text])) AND ((((storage)::jsonb ->> 'disposable_bytes'::text))::bigint >= 0) AND ((((storage)::jsonb ->> 'protected_bytes'::text))::bigint >= 0)))))
);

CREATE TABLE public.delivery_routing_responses (
    id uuid CONSTRAINT delivery_reactions_id_not_null NOT NULL,
    input_id uuid CONSTRAINT delivery_reactions_input_id_not_null NOT NULL,
    decision_ref text CONSTRAINT delivery_reactions_decision_ref_not_null NOT NULL,
    delivery_ref text CONSTRAINT delivery_reactions_delivery_ref_not_null NOT NULL,
    transport text CONSTRAINT delivery_reactions_transport_not_null NOT NULL,
    conversation_ref text CONSTRAINT delivery_reactions_conversation_ref_not_null NOT NULL,
    thread_ref text,
    source_item_ref text CONSTRAINT delivery_reactions_source_item_ref_not_null NOT NULL,
    document text CONSTRAINT delivery_reactions_document_not_null NOT NULL,
    document_fingerprint text CONSTRAINT delivery_reactions_document_fingerprint_not_null NOT NULL,
    status text DEFAULT 'pending'::text CONSTRAINT delivery_reactions_status_not_null NOT NULL,
    attempt_count bigint DEFAULT 0 CONSTRAINT delivery_reactions_attempt_count_not_null NOT NULL,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    external_receipt text,
    external_receipt_fingerprint text,
    delivered_at timestamp without time zone,
    inserted_at timestamp without time zone CONSTRAINT delivery_reactions_inserted_at_not_null NOT NULL,
    updated_at timestamp without time zone CONSTRAINT delivery_reactions_updated_at_not_null NOT NULL,
    retry_generation bigint DEFAULT 0 CONSTRAINT delivery_reactions_retry_generation_not_null NOT NULL,
    kind text NOT NULL,
    CONSTRAINT delivery_routing_response_custody_valid CHECK (((status = ANY (ARRAY['pending'::text, 'blocked'::text, 'delivered'::text])) AND (((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'pending'::text) AND (char_length(lease_ref) > 0) AND (char_length(lease_owner) > 0) AND (lease_expires_at IS NOT NULL))) AND ((status = 'pending'::text) OR (next_attempt_at IS NULL)) AND ((status <> 'blocked'::text) OR ((char_length(last_error_code) > 0) AND (char_length(last_error_detail) > 0))) AND (((status = ANY (ARRAY['pending'::text, 'blocked'::text])) AND (external_receipt IS NULL) AND (external_receipt_fingerprint IS NULL) AND (delivered_at IS NULL)) OR ((status = 'delivered'::text) AND (external_receipt IS NOT NULL) AND (char_length(external_receipt_fingerprint) = 64) AND (delivered_at IS NOT NULL))))),
    CONSTRAINT delivery_routing_response_document_valid CHECK (((jsonb_typeof((document)::jsonb) = 'object'::text) AND (((kind = 'reaction'::text) AND ((document)::jsonb ? 'emoji_name'::text) AND (((document)::jsonb - 'emoji_name'::text) = '{}'::jsonb) AND (jsonb_typeof(((document)::jsonb -> 'emoji_name'::text)) = 'string'::text) AND (char_length(((document)::jsonb ->> 'emoji_name'::text)) > 0)) OR ((kind = 'message'::text) AND ((document)::jsonb ? 'message'::text) AND (((document)::jsonb - 'message'::text) = '{}'::jsonb) AND (jsonb_typeof(((document)::jsonb -> 'message'::text)) = 'string'::text) AND (char_length(((document)::jsonb ->> 'message'::text)) > 0))))),
    CONSTRAINT delivery_routing_response_identity_valid CHECK (((char_length(decision_ref) > 0) AND (char_length(delivery_ref) > 0) AND (char_length(transport) > 0) AND (char_length(conversation_ref) > 0) AND (char_length(source_item_ref) > 0) AND (char_length(document_fingerprint) = 64) AND (attempt_count >= 0))),
    CONSTRAINT delivery_routing_responses_retry_generation_check CHECK ((retry_generation >= 0))
);

CREATE TABLE public.emisar_connection_settings (
    ref text NOT NULL,
    display_name text NOT NULL,
    rpc_url text NOT NULL,
    account_ref text NOT NULL,
    account_label text,
    enabled_for_new_work boolean DEFAULT true NOT NULL,
    monitoring_enabled boolean DEFAULT true NOT NULL,
    verified_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT emisar_connection_settings_valid CHECK (((ref ~ '^[a-z0-9][a-z0-9_.:-]{0,63}$'::text) AND ((char_length(display_name) >= 1) AND (char_length(display_name) <= 120)) AND ((char_length(rpc_url) >= 9) AND (char_length(rpc_url) <= 2048)) AND (rpc_url ~~ 'https://%'::text) AND ((char_length(account_ref) >= 1) AND (char_length(account_ref) <= 256)) AND ((account_label IS NULL) OR ((char_length(account_label) >= 1) AND (char_length(account_label) <= 256)))))
);

CREATE TABLE public.environment_repository_settings (
    environment_ref text NOT NULL,
    repository_ref text NOT NULL,
    "position" integer NOT NULL,
    CONSTRAINT environment_repository_settings_valid CHECK ((("position" >= 0) AND ("position" <= 32)))
);

CREATE TABLE public.environment_settings (
    ref text NOT NULL,
    display_name text NOT NULL,
    description text,
    emisar_connection_ref text,
    is_default boolean DEFAULT false NOT NULL,
    parallel_goal_limit integer DEFAULT 3 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT environment_settings_valid CHECK (((ref ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text) AND ((char_length(display_name) >= 1) AND (char_length(display_name) <= 80)) AND ((description IS NULL) OR ((char_length(description) >= 1) AND (char_length(description) <= 500))) AND ((parallel_goal_limit >= 1) AND (parallel_goal_limit <= 3))))
);

CREATE TABLE public.episode_case_records (
    id uuid NOT NULL,
    case_ref text NOT NULL,
    episode_id uuid NOT NULL,
    episode_key text NOT NULL,
    execution_mode text NOT NULL,
    transport text NOT NULL,
    conversation_ref text NOT NULL,
    workspace_ref text NOT NULL,
    repository_ref text,
    problem text NOT NULL,
    occurrence_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    cause text,
    attempted_actions text[] DEFAULT ARRAY[]::text[] NOT NULL,
    outcome text,
    links text[] DEFAULT ARRAY[]::text[] NOT NULL,
    anchor_keys text[] DEFAULT ARRAY[]::text[] NOT NULL,
    search_text text NOT NULL,
    source_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    closed_at timestamp without time zone NOT NULL,
    content_fingerprint text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_case_record_valid CHECK (((status = ANY (ARRAY['active'::text, 'deleted'::text])) AND (execution_mode = ANY (ARRAY['live'::text, 'shadow'::text])) AND (char_length(case_ref) > 0) AND ((char_length(problem) >= 1) AND (char_length(problem) <= 4096)) AND (char_length(search_text) <= 16384) AND (char_length(content_fingerprint) = 64) AND (cardinality(occurrence_refs) <= 64) AND (cardinality(attempted_actions) <= 32) AND (cardinality(links) <= 32) AND (cardinality(anchor_keys) <= 64) AND (cardinality(source_refs) <= 64)))
);

CREATE TABLE public.episode_correlation_claims (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    input_ref text NOT NULL,
    scope_ref text NOT NULL,
    namespace text NOT NULL,
    occurrence_ref text NOT NULL,
    lifecycle_state text DEFAULT 'active'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    established_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_correlation_claim_valid CHECK (((char_length(input_ref) > 0) AND (char_length(scope_ref) > 0) AND (char_length(namespace) > 0) AND ((char_length(occurrence_ref) >= 1) AND (char_length(occurrence_ref) <= 512)) AND (lifecycle_state = ANY (ARRAY['active'::text, 'terminal'::text])) AND (status = ANY (ARRAY['active'::text, 'retired'::text]))))
);

CREATE TABLE public.episode_emisar_approvals (
    id uuid NOT NULL,
    record_id uuid NOT NULL,
    episode_id uuid NOT NULL,
    request_id text NOT NULL,
    run_id text NOT NULL,
    operation_id text NOT NULL,
    action_id text NOT NULL,
    pack_ref text NOT NULL,
    runner_ref text NOT NULL,
    approval_url text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    status text DEFAULT 'monitoring'::text NOT NULL,
    remote_status text DEFAULT 'pending_approval'::text NOT NULL,
    run_url text,
    remote_error text,
    last_observed_at timestamp without time zone,
    terminal_at timestamp without time zone,
    resumed_at timestamp without time zone,
    failure_count bigint DEFAULT 0 NOT NULL,
    last_error text,
    next_attempt_at timestamp without time zone,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    review_digest text,
    connection_ref text,
    closed_at timestamp without time zone,
    closed_reason text,
    CONSTRAINT episode_emisar_approval_closure_valid CHECK ((((status = 'closed'::text) AND (closed_at IS NOT NULL) AND (closed_reason IS NOT NULL) AND (closed_reason = 'wait_ended'::text)) OR ((status <> 'closed'::text) AND (closed_at IS NULL) AND (closed_reason IS NULL)))),
    CONSTRAINT episode_emisar_approval_identity_valid CHECK ((((char_length(request_id) >= 1) AND (char_length(request_id) <= 80)) AND ((octet_length(run_id) >= 1) AND (octet_length(run_id) <= 200)) AND ((octet_length(operation_id) >= 1) AND (octet_length(operation_id) <= 200)) AND ((octet_length(action_id) >= 1) AND (octet_length(action_id) <= 200)) AND ((octet_length(pack_ref) >= 1) AND (octet_length(pack_ref) <= 300)) AND ((octet_length(runner_ref) >= 1) AND (octet_length(runner_ref) <= 300)) AND ((octet_length(approval_url) >= 1) AND (octet_length(approval_url) <= 2048)) AND (status = ANY (ARRAY['monitoring'::text, 'resumed'::text, 'blocked'::text, 'closed'::text])) AND (remote_status = ANY (ARRAY['pending'::text, 'pending_approval'::text, 'sent'::text, 'running'::text, 'cancelling'::text, 'success'::text, 'failed'::text, 'error'::text, 'validation_failed'::text, 'unknown_action'::text, 'cancelled'::text, 'timed_out'::text, 'refused'::text, 'denied'::text])) AND (failure_count >= 0) AND ((run_url IS NULL) OR ((octet_length(run_url) >= 1) AND (octet_length(run_url) <= 2048))) AND ((remote_error IS NULL) OR ((octet_length(remote_error) >= 1) AND (octet_length(remote_error) <= 1000))) AND ((last_error IS NULL) OR ((octet_length(last_error) >= 1) AND (octet_length(last_error) <= 4096))) AND (((status = 'resumed'::text) AND (terminal_at IS NOT NULL) AND (resumed_at IS NOT NULL)) OR ((status <> 'resumed'::text) AND (resumed_at IS NULL))))),
    CONSTRAINT episode_emisar_approval_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'monitoring'::text) AND ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024)) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT episode_emisar_approval_review_valid CHECK (((review_digest IS NULL) OR (review_digest ~ '^[0-9a-f]{64}$'::text)))
);

CREATE TABLE public.episode_event_subscriptions (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    record_id uuid NOT NULL,
    ref text NOT NULL,
    status text NOT NULL,
    source_kind text,
    matcher text NOT NULL,
    cursor text,
    poll_after timestamp without time zone,
    deadline_at timestamp without time zone,
    last_observation text,
    last_observed_at timestamp without time zone,
    resolution_kind text,
    revision bigint DEFAULT 1 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_event_subscription_valid CHECK (((octet_length(ref) >= 1) AND (octet_length(ref) <= 256) AND (status = ANY (ARRAY['active'::text, 'resolved'::text, 'timed_out'::text, 'cancelled'::text])) AND ((source_kind IS NULL) OR ((octet_length(source_kind) >= 1) AND (octet_length(source_kind) <= 120))) AND ((octet_length(matcher) >= 2) AND (octet_length(matcher) <= 32768)) AND (jsonb_typeof((matcher)::jsonb) = 'object'::text) AND ((cursor IS NULL) OR ((octet_length(cursor) >= 1) AND (octet_length(cursor) <= 16384))) AND ((cursor IS NULL) OR (jsonb_typeof((cursor)::jsonb) = ANY (ARRAY['object'::text, 'array'::text, 'string'::text, 'number'::text, 'boolean'::text, 'null'::text]))) AND ((last_observation IS NULL) OR ((octet_length(last_observation) >= 2) AND (octet_length(last_observation) <= 32768))) AND ((last_observation IS NULL) OR (jsonb_typeof((last_observation)::jsonb) = 'object'::text)) AND (poll_after <= deadline_at) AND (revision > 0) AND (((status = 'active'::text) AND (resolution_kind IS NULL)) OR ((status = 'resolved'::text) AND (resolution_kind = ANY (ARRAY['input'::text, 'poll_fallback'::text, 'timer'::text]))) OR ((status = 'timed_out'::text) AND (resolution_kind = 'deadline'::text)) OR ((status = 'cancelled'::text) AND (resolution_kind = 'cancelled'::text))))),
    CONSTRAINT event_subscription_schedule_valid CHECK ((((deadline_at IS NULL) AND (poll_after IS NULL) AND (source_kind IS NOT NULL) AND ((matcher)::jsonb <> '{}'::jsonb)) OR ((deadline_at IS NOT NULL) AND (poll_after IS NOT NULL) AND (poll_after <= deadline_at))))
);

CREATE TABLE public.episode_input_origins (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    input_ref text NOT NULL,
    sequence bigint NOT NULL,
    native_input_id text NOT NULL,
    revision bigint NOT NULL,
    source_kind text,
    source_ref text,
    source_item_ref text,
    actor_ref text NOT NULL,
    transport text NOT NULL,
    conversation_ref text NOT NULL,
    thread_ref text,
    origin_kind text NOT NULL,
    root_ref text,
    occurred_at timestamp without time zone NOT NULL,
    effective boolean DEFAULT true NOT NULL,
    correction_ref text,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_input_origin_valid CHECK (((char_length(input_ref) > 0) AND (sequence > 0) AND (revision > 0) AND (char_length(actor_ref) > 0) AND (char_length(transport) > 0) AND (char_length(conversation_ref) > 0) AND (origin_kind = ANY (ARRAY['channel_root'::text, 'thread_reply'::text, 'conversation'::text])) AND (effective OR (correction_ref IS NOT NULL))))
);

CREATE TABLE public.episode_kernel_episodes (
    id uuid NOT NULL,
    key text NOT NULL,
    state text NOT NULL,
    owner_kind text,
    owner_ref text,
    owner_deadline_at timestamp without time zone,
    destination_transport text NOT NULL,
    destination_conversation_ref text NOT NULL,
    destination_thread_ref text,
    linked_episode_id uuid,
    semantic_version bigint DEFAULT 0 NOT NULL,
    next_sequence bigint DEFAULT 1 NOT NULL,
    input_revisions jsonb DEFAULT '{}'::jsonb NOT NULL,
    active_input_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    queued_input_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    queued_input_order_keys text[] DEFAULT ARRAY[]::text[] NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    execution_mode text DEFAULT 'live'::text NOT NULL,
    history_pruned_at timestamp without time zone,
    CONSTRAINT episode_kernel_destination_not_empty CHECK (((char_length(destination_transport) > 0) AND (char_length(destination_conversation_ref) > 0))),
    CONSTRAINT episode_kernel_episode_key_not_empty CHECK ((char_length(key) > 0)),
    CONSTRAINT episode_kernel_execution_mode_valid CHECK ((execution_mode = ANY (ARRAY['live'::text, 'shadow'::text]))),
    CONSTRAINT episode_kernel_history_not_self CHECK (((linked_episode_id IS NULL) OR (linked_episode_id <> id))),
    CONSTRAINT episode_kernel_inputs_match_owner CHECK (((NOT (active_input_refs && queued_input_refs)) AND (cardinality(queued_input_refs) = cardinality(queued_input_order_keys)) AND ((owner_kind IS DISTINCT FROM 'delivery'::text) OR (cardinality(active_input_refs) = 0)) AND ((state <> ALL (ARRAY['waiting_for_input'::text, 'waiting_for_event'::text])) OR (cardinality(active_input_refs) = 0)) AND ((state <> ALL (ARRAY['complete'::text, 'cancelled'::text])) OR ((cardinality(active_input_refs) = 0) AND (cardinality(queued_input_refs) = 0))))),
    CONSTRAINT episode_kernel_owner_matches_state CHECK ((((state = ANY (ARRAY['complete'::text, 'cancelled'::text])) AND (owner_kind IS NULL) AND (owner_ref IS NULL) AND (owner_deadline_at IS NULL)) OR ((state = 'working'::text) AND (owner_kind = ANY (ARRAY['turn'::text, 'delivery'::text])) AND (char_length(owner_ref) > 0) AND (owner_deadline_at IS NULL)) OR ((state = 'waiting_for_input'::text) AND (owner_kind = 'input'::text) AND (char_length(owner_ref) > 0) AND (owner_deadline_at IS NULL)) OR ((state = 'waiting_for_event'::text) AND (owner_kind = 'event'::text) AND (char_length(owner_ref) > 0)))),
    CONSTRAINT episode_kernel_versions_nonnegative CHECK (((semantic_version >= 0) AND (next_sequence > 0)))
);

CREATE TABLE public.episode_kernel_events (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    sequence bigint NOT NULL,
    kind text NOT NULL,
    dedupe_key text NOT NULL,
    fingerprint text NOT NULL,
    payload text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_kernel_event_identity_valid CHECK (((char_length(dedupe_key) > 0) AND (char_length(fingerprint) = 64))),
    CONSTRAINT episode_kernel_event_kind_valid CHECK ((kind = ANY (ARRAY['input_admitted'::text, 'owner_transferred'::text, 'input_wait_started'::text, 'event_wait_started'::text, 'wait_resumed'::text, 'result_accepted'::text, 'delivery_confirmed'::text, 'episode_cancelled'::text, 'reaction_recorded'::text]))),
    CONSTRAINT episode_kernel_event_sequence_positive CHECK ((sequence > 0))
);

CREATE TABLE public.episode_operator_reviews (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    semantic_version bigint NOT NULL,
    actor_ref text NOT NULL,
    note text DEFAULT ''::text NOT NULL,
    reviewed_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_operator_review_valid CHECK (((semantic_version >= 0) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (octet_length(note) <= 2048)))
);

CREATE TABLE public.episode_publication_followups (
    id uuid NOT NULL,
    publication_id uuid NOT NULL,
    episode_id uuid NOT NULL,
    pr_state text DEFAULT 'open'::text NOT NULL,
    checks_state text DEFAULT 'unknown'::text NOT NULL,
    checks_total bigint DEFAULT 0 NOT NULL,
    checks_passed bigint DEFAULT 0 NOT NULL,
    checks_failed bigint DEFAULT 0 NOT NULL,
    checks_url text,
    merge_sha text,
    merged_at timestamp without time zone,
    verification_turn_ref text,
    verification_event_ref text,
    verified_at timestamp without time zone,
    next_poll_at timestamp without time zone NOT NULL,
    deadline_at timestamp without time zone NOT NULL,
    failure_count bigint DEFAULT 0 NOT NULL,
    last_error text,
    last_event_key text,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    manual_check_ref text,
    verification_sequence bigint,
    CONSTRAINT episode_publication_followup_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT episode_publication_followup_state_valid CHECK (((pr_state = ANY (ARRAY['open'::text, 'closed'::text, 'merged'::text, 'stale'::text, 'expired'::text])) AND (checks_state = ANY (ARRAY['unknown'::text, 'none'::text, 'pending'::text, 'passing'::text, 'failing'::text])) AND (checks_total >= 0) AND (checks_passed >= 0) AND (checks_failed >= 0) AND ((checks_passed + checks_failed) <= checks_total) AND ((checks_url IS NULL) OR ((octet_length(checks_url) >= 1) AND (octet_length(checks_url) <= 2048))) AND ((merge_sha IS NULL) OR (merge_sha ~ '^[a-f0-9]{40}([a-f0-9]{24})?$'::text)) AND ((last_event_key IS NULL) OR ((char_length(last_event_key) >= 1) AND (char_length(last_event_key) <= 128))) AND ((manual_check_ref IS NULL) OR ((char_length(manual_check_ref) >= 1) AND (char_length(manual_check_ref) <= 1024))) AND ((last_error IS NULL) OR ((octet_length(last_error) >= 1) AND (octet_length(last_error) <= 4096))) AND (failure_count >= 0) AND (deadline_at > inserted_at) AND (((verification_turn_ref IS NULL) AND (verification_event_ref IS NULL) AND (verification_sequence IS NULL) AND (verified_at IS NULL)) OR ((char_length(verification_turn_ref) >= 1) AND (char_length(verification_turn_ref) <= 1024) AND ((char_length(verification_event_ref) >= 1) AND (char_length(verification_event_ref) <= 1024)) AND (verification_sequence > 0)))))
);

CREATE TABLE public.episode_publication_lifecycle_events (
    id uuid NOT NULL,
    ref text NOT NULL,
    publication_id uuid NOT NULL,
    episode_id uuid NOT NULL,
    kind text NOT NULL,
    state text NOT NULL,
    summary text NOT NULL,
    observation text NOT NULL,
    source_transport text,
    source_conversation_ref text,
    source_item_ref text,
    occurred_at timestamp without time zone NOT NULL,
    delivery_state text DEFAULT 'pending'::text NOT NULL,
    delivery_ref text NOT NULL,
    delivery_receipt text,
    delivery_receipt_fingerprint text,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    attempt_count bigint DEFAULT 0 NOT NULL,
    last_error text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    wakeup_state text DEFAULT 'none'::text NOT NULL,
    CONSTRAINT episode_publication_lifecycle_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL) AND (delivery_state = 'pending'::text)))),
    CONSTRAINT episode_publication_lifecycle_valid CHECK (((char_length(ref) >= 1) AND (char_length(ref) <= 256) AND (kind = ANY (ARRAY['checks'::text, 'merged'::text, 'closed'::text, 'status'::text, 'deployment'::text, 'terraform'::text, 'verification'::text, 'deadline'::text, 'review_feedback'::text])) AND (state = ANY (ARRAY['pending'::text, 'succeeded'::text, 'failed'::text, 'stopped'::text])) AND ((octet_length(summary) >= 1) AND (octet_length(summary) <= 2048)) AND ((octet_length(observation) >= 1) AND (octet_length(observation) <= 65536)) AND (delivery_state = ANY (ARRAY['pending'::text, 'delivered'::text])) AND (wakeup_state = ANY (ARRAY['none'::text, 'pending'::text, 'admitted'::text])) AND ((char_length(delivery_ref) >= 1) AND (char_length(delivery_ref) <= 256)) AND (attempt_count >= 0) AND ((last_error IS NULL) OR ((octet_length(last_error) >= 1) AND (octet_length(last_error) <= 4096))) AND (((source_transport IS NULL) AND (source_conversation_ref IS NULL) AND (source_item_ref IS NULL)) OR ((char_length(source_transport) >= 1) AND (char_length(source_transport) <= 64) AND ((char_length(source_conversation_ref) >= 1) AND (char_length(source_conversation_ref) <= 1024)) AND ((char_length(source_item_ref) >= 1) AND (char_length(source_item_ref) <= 1024)))) AND (((delivery_receipt IS NULL) AND (delivery_receipt_fingerprint IS NULL) AND (delivery_state = 'pending'::text)) OR ((delivery_receipt IS NOT NULL) AND (char_length(delivery_receipt_fingerprint) = 64) AND (delivery_state = 'delivered'::text)))))
);

CREATE TABLE public.episode_publications (
    id uuid NOT NULL,
    ref text NOT NULL,
    episode_id uuid NOT NULL,
    record_id uuid NOT NULL,
    session_id uuid NOT NULL,
    repository text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    status text DEFAULT 'review_pending'::text NOT NULL,
    destination_transport text NOT NULL,
    destination_conversation_ref text NOT NULL,
    destination_thread_ref text,
    offer_message_ref text NOT NULL,
    review_request_ref text NOT NULL,
    review_requested_by_actor_ref text NOT NULL,
    review_requested_at timestamp without time zone NOT NULL,
    review_generation bigint DEFAULT 1 NOT NULL,
    review_expected_revision bigint,
    review_document text,
    review_fingerprint text,
    review_patch bytea,
    reviewed_at timestamp without time zone,
    review_delivery_receipt text,
    review_delivery_receipt_fingerprint text,
    approval_ref text,
    approved_by_actor_ref text,
    approved_at timestamp without time zone,
    publication_receipt text,
    publication_receipt_fingerprint text,
    published_at timestamp without time zone,
    published_delivery_receipt text,
    published_delivery_receipt_fingerprint text,
    attempt_count bigint DEFAULT 0 NOT NULL,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    github_repository text,
    branch_ref text,
    commit_sha text,
    pull_request_number bigint,
    pull_request_url text,
    recovery_generation bigint DEFAULT 1 NOT NULL,
    expected_remote_head_sha text,
    discarded_reason text,
    CONSTRAINT episode_publication_approval_valid CHECK ((((approval_ref IS NULL) AND (approved_by_actor_ref IS NULL) AND (approved_at IS NULL) AND (status = ANY (ARRAY['review_pending'::text, 'review_ready'::text, 'reviewed'::text, 'blocked'::text, 'discarded'::text]))) OR (((char_length(approval_ref) >= 1) AND (char_length(approval_ref) <= 1024)) AND ((char_length(approved_by_actor_ref) >= 1) AND (char_length(approved_by_actor_ref) <= 1024)) AND (approved_at IS NOT NULL) AND (status = ANY (ARRAY['publish_pending'::text, 'published_ready'::text, 'published'::text, 'discarded'::text]))))),
    CONSTRAINT episode_publication_discarded_reason_valid CHECK (((discarded_reason IS NULL) OR ((status = 'discarded'::text) AND (discarded_reason = 'review_session_closed'::text)))),
    CONSTRAINT episode_publication_identity_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(repository) >= 1) AND (char_length(repository) <= 256)) AND ((char_length(title) >= 1) AND (char_length(title) <= 120)) AND ((octet_length(body) >= 1) AND (octet_length(body) <= 8000)) AND ((char_length(destination_transport) >= 1) AND (char_length(destination_transport) <= 64)) AND ((char_length(destination_conversation_ref) >= 1) AND (char_length(destination_conversation_ref) <= 1024)) AND ((destination_thread_ref IS NULL) OR ((char_length(destination_thread_ref) >= 1) AND (char_length(destination_thread_ref) <= 1024))) AND ((char_length(offer_message_ref) >= 1) AND (char_length(offer_message_ref) <= 1024)) AND ((char_length(review_request_ref) >= 1) AND (char_length(review_request_ref) <= 1024)) AND ((char_length(review_requested_by_actor_ref) >= 1) AND (char_length(review_requested_by_actor_ref) <= 1024)) AND (review_generation > 0) AND (recovery_generation > 0) AND (attempt_count >= 0) AND ((review_expected_revision IS NULL) OR (review_expected_revision > 0)))),
    CONSTRAINT episode_publication_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL) AND (status = ANY (ARRAY['review_pending'::text, 'review_ready'::text, 'publish_pending'::text, 'published_ready'::text]))))),
    CONSTRAINT episode_publication_publish_valid CHECK ((((publication_receipt IS NULL) AND (publication_receipt_fingerprint IS NULL) AND (published_at IS NULL) AND (published_delivery_receipt IS NULL) AND (published_delivery_receipt_fingerprint IS NULL) AND (status <> ALL (ARRAY['published_ready'::text, 'published'::text]))) OR ((publication_receipt IS NOT NULL) AND (char_length(publication_receipt_fingerprint) = 64) AND (published_at IS NOT NULL) AND (((published_delivery_receipt IS NULL) AND (published_delivery_receipt_fingerprint IS NULL) AND (status = 'published_ready'::text)) OR ((published_delivery_receipt IS NOT NULL) AND (char_length(published_delivery_receipt_fingerprint) = 64) AND (status = ANY (ARRAY['published'::text, 'discarded'::text]))))))),
    CONSTRAINT episode_publication_remote_identity_valid CHECK ((((github_repository IS NULL) AND (branch_ref IS NULL) AND (commit_sha IS NULL) AND (pull_request_number IS NULL) AND (pull_request_url IS NULL) AND (expected_remote_head_sha IS NULL)) OR ((github_repository ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'::text) AND (branch_ref ~ '^refs/heads/[A-Za-z0-9._/-]{1,240}$'::text) AND (commit_sha ~ '^[a-f0-9]{40}([a-f0-9]{24})?$'::text) AND (pull_request_number > 0) AND ((octet_length(pull_request_url) >= 1) AND (octet_length(pull_request_url) <= 2048)) AND ((expected_remote_head_sha IS NULL) OR (expected_remote_head_sha ~ '^[a-f0-9]{40}([a-f0-9]{24})?$'::text))))),
    CONSTRAINT episode_publication_review_valid CHECK ((((review_document IS NULL) AND (review_fingerprint IS NULL) AND (review_patch IS NULL) AND (reviewed_at IS NULL) AND (review_delivery_receipt IS NULL) AND (review_delivery_receipt_fingerprint IS NULL) AND (status = ANY (ARRAY['review_pending'::text, 'discarded'::text]))) OR ((review_document IS NOT NULL) AND (char_length(review_fingerprint) = 64) AND (reviewed_at IS NOT NULL) AND (((review_delivery_receipt IS NULL) AND (review_delivery_receipt_fingerprint IS NULL) AND (status = 'review_ready'::text)) OR ((review_delivery_receipt IS NOT NULL) AND (char_length(review_delivery_receipt_fingerprint) = 64) AND (status = ANY (ARRAY['reviewed'::text, 'publish_pending'::text, 'published_ready'::text, 'published'::text, 'blocked'::text, 'discarded'::text])))))))
);

CREATE TABLE public.episode_routing_digests (
    episode_id uuid NOT NULL,
    objective text NOT NULL,
    latest_development text,
    search_text text NOT NULL,
    anchor_keys text[] DEFAULT ARRAY[]::text[] NOT NULL,
    conversation_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    input_count integer DEFAULT 0 NOT NULL,
    covered_through_sequence bigint NOT NULL,
    covered_through_at timestamp without time zone NOT NULL,
    latest_revision bigint NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    title text,
    title_turn_id uuid,
    title_updated_at timestamp without time zone,
    search_vector tsvector GENERATED ALWAYS AS ((((setweight(to_tsvector('english'::regconfig, COALESCE(title, ''::text)), 'A'::"char") || setweight(to_tsvector('english'::regconfig, COALESCE(objective, ''::text)), 'B'::"char")) || setweight(to_tsvector('english'::regconfig, COALESCE(latest_development, ''::text)), 'B'::"char")) || setweight(to_tsvector('english'::regconfig, COALESCE(search_text, ''::text)), 'C'::"char"))) STORED,
    CONSTRAINT episode_routing_digest_title_valid CHECK ((((title IS NULL) AND (title_turn_id IS NULL) AND (title_updated_at IS NULL)) OR (((char_length(title) >= 1) AND (char_length(title) <= 80)) AND (title !~ '[\n\r]'::text) AND (title_turn_id IS NOT NULL) AND (title_updated_at IS NOT NULL)))),
    CONSTRAINT episode_routing_digest_valid CHECK (((char_length(objective) > 0) AND (char_length(search_text) > 0) AND (input_count >= 0) AND (covered_through_sequence > 0) AND (latest_revision > 0) AND (cardinality(anchor_keys) <= 64) AND (cardinality(conversation_refs) <= 32)))
);

CREATE TABLE public.episode_schedule_occurrences (
    id uuid NOT NULL,
    ref text NOT NULL,
    schedule_id uuid NOT NULL,
    scheduled_for timestamp without time zone NOT NULL,
    status text NOT NULL,
    child_episode_id uuid,
    event_ref text,
    missed_reason text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    trigger text DEFAULT 'scheduled'::text NOT NULL,
    CONSTRAINT episode_schedule_occurrence_trigger_valid CHECK ((trigger = ANY (ARRAY['scheduled'::text, 'manual'::text]))),
    CONSTRAINT episode_schedule_occurrence_valid CHECK (((char_length(ref) >= 1) AND (char_length(ref) <= 256) AND (status = ANY (ARRAY['dispatched'::text, 'missed'::text])) AND (((status = 'dispatched'::text) AND (child_episode_id IS NOT NULL) AND ((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024)) AND (missed_reason IS NULL)) OR ((status = 'missed'::text) AND (child_episode_id IS NULL) AND (event_ref IS NULL) AND ((octet_length(missed_reason) >= 1) AND (octet_length(missed_reason) <= 1024))))))
);

CREATE TABLE public.episode_schedules (
    id uuid NOT NULL,
    ref text NOT NULL,
    offer_record_id uuid NOT NULL,
    source_episode_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    title text NOT NULL,
    task text NOT NULL,
    recurrence text NOT NULL,
    timezone text NOT NULL,
    authority text NOT NULL,
    repository text,
    destination_transport text NOT NULL,
    destination_conversation_ref text NOT NULL,
    destination_thread_ref text,
    confirmed_by_actor_ref text NOT NULL,
    confirmation_ref text NOT NULL,
    confirmed_at timestamp without time zone NOT NULL,
    next_occurrence_at timestamp without time zone,
    expires_at timestamp without time zone,
    failure_count bigint DEFAULT 0 NOT NULL,
    last_error text,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    environment_ref text,
    CONSTRAINT episode_schedule_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'active'::text) AND ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024)) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT episode_schedule_revision_valid CHECK ((revision > 0)),
    CONSTRAINT episode_schedules_environment_valid CHECK (((environment_ref IS NULL) OR (environment_ref ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text)))
);

CREATE TABLE public.episode_state_record_responses (
    id uuid NOT NULL,
    record_id uuid NOT NULL,
    inbox_entry_id uuid NOT NULL,
    response_ref text NOT NULL,
    actor_ref text NOT NULL,
    choice_index integer,
    choice text,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_state_record_response_valid CHECK ((((char_length(response_ref) >= 1) AND (char_length(response_ref) <= 1024)) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (((choice_index IS NULL) AND (choice IS NULL)) OR ((choice_index IS NOT NULL) AND (choice IS NOT NULL) AND ((choice_index >= 0) AND (choice_index <= 9)) AND ((char_length(choice) >= 1) AND (char_length(choice) <= 240))))))
);

CREATE TABLE public.episode_state_records (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    ref text NOT NULL,
    operation_id text NOT NULL,
    kind text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    continuation text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    confirmed_episode_id uuid,
    confirmation_ref text,
    confirmed_by_actor_ref text,
    confirmed_at timestamp without time zone,
    subject_ref text,
    sequence bigint NOT NULL,
    wait_error character varying(32),
    CONSTRAINT episode_state_record_confirmation_valid CHECK ((((status = 'confirmed'::text) AND (char_length(confirmation_ref) > 0) AND (char_length(confirmed_by_actor_ref) > 0) AND (confirmed_at IS NOT NULL) AND (((kind = ANY (ARRAY['schedule_offer'::text, 'memory_offer'::text, 'preference_offer'::text, 'guidance_offer'::text, 'standing_assignment_offer'::text, 'automation_change_offer'::text, 'slack_post_offer'::text])) AND (confirmed_episode_id IS NULL)) OR ((kind <> ALL (ARRAY['schedule_offer'::text, 'memory_offer'::text, 'preference_offer'::text, 'guidance_offer'::text, 'standing_assignment_offer'::text, 'automation_change_offer'::text, 'slack_post_offer'::text])) AND (confirmed_episode_id IS NOT NULL)))) OR ((status <> 'confirmed'::text) AND (confirmed_episode_id IS NULL) AND (confirmation_ref IS NULL) AND (confirmed_by_actor_ref IS NULL) AND (confirmed_at IS NULL)))),
    CONSTRAINT episode_state_record_identity_valid CHECK (((char_length(ref) >= 1) AND (char_length(ref) <= 256) AND ((char_length(operation_id) >= 1) AND (char_length(operation_id) <= 80)) AND (kind = ANY (ARRAY['task_offer'::text, 'publication_offer'::text, 'schedule_offer'::text, 'memory_offer'::text, 'preference_offer'::text, 'guidance_offer'::text, 'standing_assignment_offer'::text, 'slack_post_offer'::text, 'input_request'::text, 'event_wait'::text, 'emisar_approval'::text, 'evidence'::text, 'coverage'::text, 'finding'::text, 'progress'::text, 'goal'::text, 'goal_state'::text, 'alert_assessment'::text, 'automation_change_offer'::text])) AND (status = ANY (ARRAY['open'::text, 'confirmed'::text, 'answered'::text, 'dismissed'::text, 'superseded'::text])) AND (char_length(payload_fingerprint) = 64) AND (((kind = ANY (ARRAY['goal'::text, 'goal_state'::text])) AND ((char_length(subject_ref) >= 1) AND (char_length(subject_ref) <= 120))) OR ((kind <> ALL (ARRAY['goal'::text, 'goal_state'::text])) AND (subject_ref IS NULL))))),
    CONSTRAINT episode_state_record_wait_error_valid CHECK (((wait_error IS NULL) OR ((kind = 'event_wait'::text) AND ((wait_error)::text = ANY ((ARRAY['deadline'::character varying, 'poll_after'::character varying, 'timer_deadline'::character varying, 'source_kind'::character varying, 'cursor'::character varying])::text[])))))
);

CREATE SEQUENCE public.episode_state_records_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.episode_state_records_sequence_seq OWNED BY public.episode_state_records.sequence;

CREATE TABLE public.episode_work_activity (
    id uuid NOT NULL,
    episode_id uuid,
    session_id uuid NOT NULL,
    remote_event_id text NOT NULL,
    remote_session_id text NOT NULL,
    coop_turn_id text,
    sequence bigint NOT NULL,
    kind text NOT NULL,
    version integer NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    remote_payload_fingerprint text,
    operational_pruned_at timestamp without time zone,
    admission_input_id uuid,
    CONSTRAINT activity_owner_valid CHECK (((episode_id IS NOT NULL) <> (admission_input_id IS NOT NULL))),
    CONSTRAINT episode_work_activity_identity_valid CHECK (((sequence > 0) AND (version > 0) AND (version <= 65535) AND ((char_length(remote_event_id) >= 1) AND (char_length(remote_event_id) <= 512)) AND ((char_length(remote_session_id) >= 1) AND (char_length(remote_session_id) <= 512)) AND ((char_length(kind) >= 1) AND (char_length(kind) <= 128)) AND ((coop_turn_id IS NULL) OR ((char_length(coop_turn_id) >= 1) AND (char_length(coop_turn_id) <= 512))) AND (char_length(payload_fingerprint) = 64)))
);

CREATE TABLE public.episode_work_knowledge_exposures (
    session_id uuid NOT NULL,
    knowledge_id uuid NOT NULL,
    version bigint NOT NULL,
    turn_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);

CREATE TABLE public.episode_work_sessions (
    id uuid NOT NULL,
    episode_id uuid,
    policy text NOT NULL,
    policy_digest text NOT NULL,
    external_ref text NOT NULL,
    generation bigint DEFAULT 1 NOT NULL,
    create_generation bigint DEFAULT 1 NOT NULL,
    coop_session_id text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    execution_kind text DEFAULT 'work'::text NOT NULL,
    repository_ref text,
    cleanup_status text DEFAULT 'active'::text NOT NULL,
    cleanup_attempt_count bigint DEFAULT 0 NOT NULL,
    cleanup_lease_ref text,
    cleanup_lease_owner text,
    cleanup_lease_expires_at timestamp without time zone,
    cleanup_next_attempt_at timestamp without time zone,
    cleanup_last_error_code text,
    cleanup_last_error_detail text,
    close_generation bigint DEFAULT 1 NOT NULL,
    close_expected_revision bigint,
    closed_at timestamp without time zone,
    discard_after timestamp without time zone,
    discard_plan_generation bigint DEFAULT 1 NOT NULL,
    discard_plan_expected_revision bigint,
    discard_plan_accept_unmerged boolean DEFAULT false NOT NULL,
    discard_plan_operation_id text,
    discard_plan text,
    discard_plan_fingerprint text,
    discard_generation bigint DEFAULT 1 NOT NULL,
    cleanup_receipt text,
    cleanup_receipt_fingerprint text,
    retained_reason text,
    discarded_at timestamp without time zone,
    cleanup_blocked_from text,
    workspace_task text,
    authority_digest text,
    repository_context text,
    activity_cursor bigint DEFAULT 0 NOT NULL,
    activity_sync_pending boolean DEFAULT false NOT NULL,
    admission_input_id uuid,
    learning_run_id uuid,
    source_exposure_count bigint,
    knowledge_exposure_count bigint,
    repository_source text,
    emisar_connection_ref text,
    emisar_account_ref text,
    emisar_rpc_url text,
    environment_ref text,
    CONSTRAINT episode_work_session_activity_cursor_valid CHECK ((activity_cursor >= 0)),
    CONSTRAINT episode_work_session_cleanup_blocked_valid CHECK ((((cleanup_status = 'blocked'::text) AND ((cleanup_blocked_from IS NULL) OR (cleanup_blocked_from = ANY (ARRAY['close_pending'::text, 'plan_pending'::text, 'discard_pending'::text])))) OR ((cleanup_status <> 'blocked'::text) AND (cleanup_blocked_from IS NULL)))),
    CONSTRAINT episode_work_session_cleanup_lease_valid CHECK ((((cleanup_lease_ref IS NULL) AND (cleanup_lease_owner IS NULL) AND (cleanup_lease_expires_at IS NULL)) OR (((char_length(cleanup_lease_ref) >= 1) AND (char_length(cleanup_lease_ref) <= 1024)) AND ((char_length(cleanup_lease_owner) >= 1) AND (char_length(cleanup_lease_owner) <= 1024)) AND (cleanup_lease_expires_at IS NOT NULL) AND (cleanup_status = ANY (ARRAY['close_pending'::text, 'plan_pending'::text, 'discard_pending'::text]))))),
    CONSTRAINT episode_work_session_cleanup_receipt_valid CHECK ((((cleanup_receipt IS NULL) AND (cleanup_receipt_fingerprint IS NULL)) OR ((cleanup_receipt IS NOT NULL) AND (char_length(cleanup_receipt_fingerprint) = 64)))),
    CONSTRAINT episode_work_session_cleanup_state_valid CHECK (((cleanup_status = ANY (ARRAY['active'::text, 'close_pending'::text, 'grace'::text, 'plan_pending'::text, 'discard_pending'::text, 'retained'::text, 'discarded'::text, 'blocked'::text])) AND (cleanup_attempt_count >= 0) AND (close_generation > 0) AND (discard_plan_generation > 0) AND (discard_generation > 0) AND ((close_expected_revision IS NULL) OR (close_expected_revision > 0)) AND ((discard_plan_expected_revision IS NULL) OR (discard_plan_expected_revision > 0)))),
    CONSTRAINT episode_work_session_discard_plan_valid CHECK ((((discard_plan_operation_id IS NULL) AND (discard_plan IS NULL) AND (discard_plan_fingerprint IS NULL)) OR (((char_length(discard_plan_operation_id) >= 1) AND (char_length(discard_plan_operation_id) <= 1024)) AND (discard_plan IS NOT NULL) AND (char_length(discard_plan_fingerprint) = 64)))),
    CONSTRAINT episode_work_session_emisar_pin_valid CHECK ((((emisar_connection_ref IS NULL) AND (emisar_account_ref IS NULL) AND (emisar_rpc_url IS NULL)) OR (((char_length(emisar_connection_ref) >= 1) AND (char_length(emisar_connection_ref) <= 64)) AND ((char_length(emisar_account_ref) >= 1) AND (char_length(emisar_account_ref) <= 256)) AND ((char_length(emisar_rpc_url) >= 9) AND (char_length(emisar_rpc_url) <= 2048))))),
    CONSTRAINT episode_work_session_environment_valid CHECK (((environment_ref IS NULL) OR ((execution_kind = 'work'::text) AND (environment_ref ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text)))),
    CONSTRAINT episode_work_session_identity_valid CHECK (((char_length(policy) > 0) AND (generation > 0) AND (create_generation > 0) AND (char_length(policy_digest) = 64) AND (char_length(external_ref) > 0) AND ((authority_digest IS NULL) OR (authority_digest ~ '^[0-9a-f]{64}$'::text)))),
    CONSTRAINT episode_work_session_owner_valid CHECK ((((execution_kind = 'work'::text) AND (episode_id IS NOT NULL) AND (admission_input_id IS NULL) AND (learning_run_id IS NULL)) OR ((execution_kind = 'admission'::text) AND (episode_id IS NULL) AND (learning_run_id IS NULL) AND (repository_ref IS NULL) AND (repository_context IS NULL) AND (workspace_task IS NULL)) OR ((execution_kind = 'learning'::text) AND (episode_id IS NULL) AND (admission_input_id IS NULL) AND (learning_run_id IS NOT NULL) AND (repository_ref IS NULL) AND (repository_context IS NULL) AND (workspace_task IS NULL) AND (authority_digest IS NULL)))),
    CONSTRAINT episode_work_session_repository_context_valid CHECK (((repository_context IS NULL) OR (((octet_length(repository_context) >= 1) AND (octet_length(repository_context) <= 16384)) AND (jsonb_typeof((repository_context)::jsonb) = 'object'::text) AND ((repository_context)::jsonb ?& ARRAY['context_ref'::text, 'parallel_goal_limit'::text, 'primary_repository'::text, 'read_only_repositories'::text]) AND ((((((repository_context)::jsonb - 'context_ref'::text) - 'parallel_goal_limit'::text) - 'primary_repository'::text) - 'read_only_repositories'::text) = '{}'::jsonb) AND (jsonb_typeof(((repository_context)::jsonb -> 'context_ref'::text)) = 'string'::text) AND ((char_length(((repository_context)::jsonb ->> 'context_ref'::text)) >= 1) AND (char_length(((repository_context)::jsonb ->> 'context_ref'::text)) <= 256)) AND (jsonb_typeof(((repository_context)::jsonb -> 'primary_repository'::text)) = 'string'::text) AND (((repository_context)::jsonb ->> 'primary_repository'::text) = repository_ref) AND (jsonb_typeof(((repository_context)::jsonb -> 'parallel_goal_limit'::text)) = 'number'::text) AND (((repository_context)::jsonb ->> 'parallel_goal_limit'::text) ~ '^[1-3]$'::text) AND (jsonb_typeof(((repository_context)::jsonb -> 'read_only_repositories'::text)) = 'array'::text) AND (jsonb_array_length(((repository_context)::jsonb -> 'read_only_repositories'::text)) <= 32) AND (NOT (((repository_context)::jsonb -> 'read_only_repositories'::text) @> jsonb_build_array(repository_ref)))))),
    CONSTRAINT episode_work_session_repository_source_valid CHECK (((repository_source IS NULL) OR ((repository_ref IS NOT NULL) AND ((octet_length(repository_source) >= 1) AND (octet_length(repository_source) <= 1024)) AND (jsonb_typeof((repository_source)::jsonb) = 'object'::text) AND ((repository_source)::jsonb ? 'kind'::text) AND (jsonb_typeof(((repository_source)::jsonb -> 'kind'::text)) = 'string'::text) AND (((((repository_source)::jsonb ->> 'kind'::text) = 'default'::text) AND (((repository_source)::jsonb - 'kind'::text) = '{}'::jsonb)) OR ((((repository_source)::jsonb ->> 'kind'::text) = 'branch'::text) AND ((repository_source)::jsonb ?& ARRAY['kind'::text, 'name'::text]) AND ((((repository_source)::jsonb - 'kind'::text) - 'name'::text) = '{}'::jsonb) AND (jsonb_typeof(((repository_source)::jsonb -> 'name'::text)) = 'string'::text) AND ((octet_length(((repository_source)::jsonb ->> 'name'::text)) >= 1) AND (octet_length(((repository_source)::jsonb ->> 'name'::text)) <= 255))) OR ((((repository_source)::jsonb ->> 'kind'::text) = 'pull_request'::text) AND ((repository_source)::jsonb ?& ARRAY['kind'::text, 'number'::text]) AND ((((repository_source)::jsonb - 'kind'::text) - 'number'::text) = '{}'::jsonb) AND (jsonb_typeof(((repository_source)::jsonb -> 'number'::text)) = 'number'::text) AND (((repository_source)::jsonb ->> 'number'::text) ~ '^([1-9][0-9]{0,6}|10000000)$'::text)) OR ((((repository_source)::jsonb ->> 'kind'::text) = 'commit'::text) AND ((repository_source)::jsonb ?& ARRAY['kind'::text, 'sha'::text]) AND ((((repository_source)::jsonb - 'kind'::text) - 'sha'::text) = '{}'::jsonb) AND (jsonb_typeof(((repository_source)::jsonb -> 'sha'::text)) = 'string'::text) AND (((repository_source)::jsonb ->> 'sha'::text) ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'::text)))))),
    CONSTRAINT episode_work_session_repository_valid CHECK (((repository_ref IS NULL) OR (char_length(repository_ref) > 0))),
    CONSTRAINT episode_work_session_workspace_task_valid CHECK (((workspace_task IS NULL) OR (octet_length(workspace_task) <= 65536))),
    CONSTRAINT work_source_exposure_counts_valid CHECK ((((source_exposure_count IS NULL) AND (knowledge_exposure_count IS NULL)) OR ((source_exposure_count >= 0) AND (knowledge_exposure_count >= 0) AND (source_exposure_count IS NOT NULL) AND (knowledge_exposure_count IS NOT NULL))))
);

CREATE TABLE public.episode_work_source_exposures (
    session_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    source_input_id uuid NOT NULL,
    receipt text NOT NULL
);

CREATE TABLE public.episode_work_state_tool_calls (
    id uuid NOT NULL,
    turn_id uuid NOT NULL,
    tool text NOT NULL,
    status text NOT NULL,
    arguments text,
    error text,
    called_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_work_state_tool_call_valid CHECK ((((char_length(tool) >= 1) AND (char_length(tool) <= 256)) AND (status = ANY (ARRAY['completed'::text, 'failed'::text])) AND (((status = 'completed'::text) AND (error IS NULL)) OR ((status = 'failed'::text) AND (error IS NOT NULL))) AND ((arguments IS NULL) OR (octet_length(arguments) <= 131072)) AND ((error IS NULL) OR (octet_length(error) <= 131072))))
);

CREATE TABLE public.episode_work_turns (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    turn_ref text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    session_id uuid NOT NULL,
    submit_generation bigint DEFAULT 1 NOT NULL,
    validation_generation bigint DEFAULT 1 NOT NULL,
    cancel_generation bigint DEFAULT 1 NOT NULL,
    cancel_expected_revision bigint,
    close_expected_revision bigint,
    submission text,
    submission_fingerprint text,
    coop_turn_id text,
    candidate text,
    candidate_sha256 text,
    candidate_attempt bigint,
    validation_intent text,
    validation_intent_fingerprint text,
    validation_receipt text,
    cancellation_intent text,
    cancellation_intent_fingerprint text,
    cancellation_receipt text,
    cancellation_receipt_fingerprint text,
    remote_operation_kind text,
    remote_operation_key text,
    remote_operation_revision bigint,
    result_ref text,
    delivery_ref text,
    delivery_document text,
    delivery_fingerprint text,
    continuation text,
    external_receipt text,
    external_receipt_fingerprint text,
    work_attempt_count bigint DEFAULT 0 NOT NULL,
    cancel_attempt_count bigint DEFAULT 0 NOT NULL,
    delivery_attempt_count bigint DEFAULT 0 NOT NULL,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    accepted_at timestamp without time zone,
    cancelled_at timestamp without time zone,
    delivered_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    delivery_retry_generation bigint DEFAULT 0 NOT NULL,
    operational_pruned_at timestamp without time zone,
    state_tools_endpoint text,
    state_tools_token_sha256 text,
    final_preflight_candidate_sha256 text,
    final_preflight_ledger_sha256 text,
    final_preflight_semantic_version bigint,
    execution_target text,
    usage_recorded boolean DEFAULT false NOT NULL,
    usage_input_tokens bigint,
    usage_cached_input_tokens bigint,
    usage_output_tokens bigint,
    usage_reasoning_tokens bigint,
    usage_cost_usd numeric(24,12),
    usage_cost_recorded boolean,
    timing_recorded boolean DEFAULT false NOT NULL,
    remote_queued_at timestamp without time zone,
    remote_started_at timestamp without time zone,
    remote_finished_at timestamp without time zone,
    usage_queued_ms bigint,
    usage_provider_ms bigint,
    usage_host_ms bigint,
    measurement_error_code text,
    final_preflight_continuity_sha256 text,
    validation_history text DEFAULT '[]'::text NOT NULL,
    summary_error_code text,
    completion_receipt text,
    selected_input_refs text[],
    selection_ledger text,
    delivery_target text,
    CONSTRAINT episode_work_turn_cancellation_valid CHECK ((((cancellation_intent IS NULL) AND (cancellation_intent_fingerprint IS NULL) AND (cancellation_receipt IS NULL) AND (cancellation_receipt_fingerprint IS NULL) AND (cancelled_at IS NULL)) OR ((cancellation_intent IS NOT NULL) AND (char_length(cancellation_intent_fingerprint) = 64) AND (((cancellation_receipt IS NULL) AND (cancellation_receipt_fingerprint IS NULL) AND (cancelled_at IS NULL)) OR ((cancellation_receipt IS NOT NULL) AND (char_length(cancellation_receipt_fingerprint) = 64) AND (cancelled_at IS NOT NULL)))))),
    CONSTRAINT episode_work_turn_candidate_valid CHECK ((((candidate IS NULL) AND (candidate_sha256 IS NULL) AND (candidate_attempt IS NULL) AND (validation_intent IS NULL) AND (validation_intent_fingerprint IS NULL) AND (validation_receipt IS NULL) AND (result_ref IS NULL) AND (accepted_at IS NULL) AND (continuation IS NULL)) OR ((candidate IS NOT NULL) AND (octet_length(candidate) <= 262144) AND (char_length(candidate_sha256) = 64) AND (candidate_attempt > 0) AND (validation_receipt IS NULL) AND (result_ref IS NULL) AND (accepted_at IS NULL) AND (continuation IS NULL)) OR ((candidate IS NOT NULL) AND (octet_length(candidate) <= 262144) AND (char_length(candidate_sha256) = 64) AND (candidate_attempt > 0) AND (validation_intent IS NOT NULL) AND (char_length(validation_intent_fingerprint) = 64) AND (char_length(validation_receipt) > 0) AND (char_length(result_ref) > 0) AND (accepted_at IS NOT NULL) AND (continuation IS NOT NULL)))),
    CONSTRAINT episode_work_turn_completion_receipt_valid CHECK (((completion_receipt IS NULL) OR ((coop_turn_id IS NOT NULL) AND (candidate_sha256 IS NOT NULL) AND (validation_intent IS NOT NULL)))),
    CONSTRAINT episode_work_turn_custody_valid CHECK (((status = ANY (ARRAY['pending'::text, 'cancel_pending'::text, 'delivery_pending'::text, 'settled'::text, 'blocked'::text, 'superseded'::text])) AND (((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = ANY (ARRAY['pending'::text, 'cancel_pending'::text, 'delivery_pending'::text])) AND (char_length(lease_ref) > 0) AND (char_length(lease_owner) > 0) AND (lease_expires_at IS NOT NULL))) AND ((status = ANY (ARRAY['pending'::text, 'cancel_pending'::text, 'delivery_pending'::text])) OR (next_attempt_at IS NULL)) AND ((status <> 'cancel_pending'::text) OR ((cancellation_intent IS NOT NULL) AND (cancellation_receipt IS NULL) AND (cancelled_at IS NULL))) AND ((status <> ALL (ARRAY['delivery_pending'::text, 'settled'::text])) OR ((candidate IS NOT NULL) AND (validation_receipt IS NOT NULL) AND (result_ref IS NOT NULL) AND (accepted_at IS NOT NULL))) AND ((status <> 'delivery_pending'::text) OR ((delivery_ref IS NOT NULL) AND (external_receipt IS NULL) AND (delivered_at IS NULL))) AND ((status <> 'settled'::text) OR (delivery_ref IS NULL) OR ((external_receipt IS NOT NULL) AND (delivered_at IS NOT NULL))))),
    CONSTRAINT episode_work_turn_delivery_valid CHECK ((((delivery_ref IS NULL) AND (delivery_document IS NULL) AND (delivery_fingerprint IS NULL) AND (external_receipt IS NULL) AND (external_receipt_fingerprint IS NULL) AND (delivered_at IS NULL)) OR ((char_length(delivery_ref) > 0) AND (delivery_document IS NOT NULL) AND (char_length(delivery_fingerprint) = 64) AND (((external_receipt IS NULL) AND (external_receipt_fingerprint IS NULL) AND (delivered_at IS NULL)) OR ((external_receipt IS NOT NULL) AND (char_length(external_receipt_fingerprint) = 64) AND (delivered_at IS NOT NULL)))))),
    CONSTRAINT episode_work_turn_execution_target_valid CHECK (((execution_target IS NULL) OR ((octet_length(execution_target) >= 1) AND (octet_length(execution_target) <= 512)))),
    CONSTRAINT episode_work_turn_final_preflight_valid CHECK ((((final_preflight_candidate_sha256 IS NULL) AND (final_preflight_continuity_sha256 IS NULL) AND (final_preflight_ledger_sha256 IS NULL) AND (final_preflight_semantic_version IS NULL)) OR ((final_preflight_candidate_sha256 ~ '^[0-9a-f]{64}$'::text) AND (final_preflight_continuity_sha256 ~ '^[0-9a-f]{64}$'::text) AND (final_preflight_ledger_sha256 ~ '^[0-9a-f]{64}$'::text) AND (final_preflight_semantic_version >= 0)))),
    CONSTRAINT episode_work_turn_generations_valid CHECK (((submit_generation > 0) AND (validation_generation > 0) AND (cancel_generation > 0) AND (work_attempt_count >= 0) AND (cancel_attempt_count >= 0) AND (delivery_attempt_count >= 0) AND ((cancel_expected_revision IS NULL) OR (cancel_expected_revision > 0)) AND ((close_expected_revision IS NULL) OR (close_expected_revision > 0)))),
    CONSTRAINT episode_work_turn_identity_valid CHECK ((char_length(turn_ref) > 0)),
    CONSTRAINT episode_work_turn_measurement_error_valid CHECK (((measurement_error_code IS NULL) OR ((octet_length(measurement_error_code) >= 1) AND (octet_length(measurement_error_code) <= 256)))),
    CONSTRAINT episode_work_turn_remote_operation_valid CHECK ((((remote_operation_kind IS NULL) AND (remote_operation_key IS NULL) AND (remote_operation_revision IS NULL)) OR ((remote_operation_kind = 'create_session'::text) AND (char_length(remote_operation_key) > 0) AND (remote_operation_revision IS NULL) AND (status = ANY (ARRAY['pending'::text, 'cancel_pending'::text]))) OR ((remote_operation_kind = 'submit_turn'::text) AND (char_length(remote_operation_key) > 0) AND (remote_operation_revision > 0) AND (status = ANY (ARRAY['pending'::text, 'cancel_pending'::text]))))),
    CONSTRAINT episode_work_turn_selected_inputs_valid CHECK (((selected_input_refs IS NULL) OR ((array_length(selected_input_refs, 1) IS NOT NULL) AND (array_length(selected_input_refs, 1) <= 40) AND (array_position(selected_input_refs, NULL::text) IS NULL)))),
    CONSTRAINT episode_work_turn_selection_ledger_valid CHECK (((selection_ledger IS NULL) OR ((octet_length(selection_ledger) >= 2) AND (octet_length(selection_ledger) <= 4096)))),
    CONSTRAINT episode_work_turn_state_tools_binding_valid CHECK ((((state_tools_endpoint IS NULL) AND (state_tools_token_sha256 IS NULL)) OR ((state_tools_endpoint IS NOT NULL) AND ((octet_length(state_tools_endpoint) >= 1) AND (octet_length(state_tools_endpoint) <= 2048)) AND (state_tools_token_sha256 IS NOT NULL) AND (char_length(state_tools_token_sha256) = 64)))),
    CONSTRAINT episode_work_turn_submission_valid CHECK ((((submission IS NULL) AND (submission_fingerprint IS NULL)) OR ((submission IS NOT NULL) AND (char_length(submission_fingerprint) = 64)))),
    CONSTRAINT episode_work_turn_timing_valid CHECK ((((timing_recorded = false) AND (remote_queued_at IS NULL) AND (remote_started_at IS NULL) AND (remote_finished_at IS NULL) AND (usage_queued_ms IS NULL) AND (usage_provider_ms IS NULL) AND (usage_host_ms IS NULL)) OR ((timing_recorded = true) AND (remote_queued_at IS NOT NULL) AND (remote_started_at IS NOT NULL) AND (remote_finished_at IS NOT NULL) AND (remote_queued_at <= remote_started_at) AND (remote_started_at <= remote_finished_at) AND (usage_queued_ms >= 0) AND (usage_provider_ms >= 0) AND (usage_host_ms >= 0)))),
    CONSTRAINT episode_work_turn_usage_valid CHECK ((((usage_recorded = false) AND (usage_input_tokens IS NULL) AND (usage_cached_input_tokens IS NULL) AND (usage_output_tokens IS NULL) AND (usage_reasoning_tokens IS NULL) AND (usage_cost_usd IS NULL) AND (usage_cost_recorded IS NULL)) OR ((usage_recorded = true) AND (usage_input_tokens >= 0) AND (usage_cached_input_tokens >= 0) AND (usage_output_tokens >= 0) AND (usage_reasoning_tokens >= 0) AND (usage_cost_usd >= (0)::numeric) AND (usage_cost_recorded IS NOT NULL)))),
    CONSTRAINT episode_work_turn_validation_history_valid CHECK (((jsonb_typeof((validation_history)::jsonb) = 'array'::text) AND (octet_length(validation_history) <= 262144))),
    CONSTRAINT episode_work_turn_validation_intent_valid CHECK ((((validation_intent IS NULL) AND (validation_intent_fingerprint IS NULL)) OR ((validation_intent IS NOT NULL) AND (char_length(validation_intent_fingerprint) = 64)))),
    CONSTRAINT episode_work_turns_delivery_retry_generation_check CHECK ((delivery_retry_generation >= 0))
);

CREATE TABLE public.execution_usage (
    id uuid NOT NULL,
    kind text NOT NULL,
    source_id uuid NOT NULL,
    generation text NOT NULL,
    episode_id uuid,
    session_id uuid,
    transport text NOT NULL,
    conversation_ref text NOT NULL,
    repository_ref text,
    execution_mode text NOT NULL,
    remote_ref text,
    status text NOT NULL,
    execution_target text,
    usage_recorded boolean DEFAULT false NOT NULL,
    usage_cost_recorded boolean DEFAULT false NOT NULL,
    usage_cost_usd numeric(30,12),
    timing_recorded boolean DEFAULT false NOT NULL,
    measurement_error_code text,
    usage_input_tokens bigint,
    usage_cached_input_tokens bigint,
    usage_output_tokens bigint,
    usage_reasoning_tokens bigint,
    usage_queued_ms bigint,
    usage_provider_ms bigint,
    usage_host_ms bigint,
    remote_queued_at timestamp without time zone,
    remote_started_at timestamp without time zone,
    remote_finished_at timestamp without time zone,
    recorded_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT execution_usage_cost_valid CHECK (((usage_cost_recorded AND (usage_cost_usd >= (0)::numeric) AND (usage_cost_usd <= (1000000000)::numeric)) OR ((NOT usage_cost_recorded) AND (usage_cost_usd IS NULL)))),
    CONSTRAINT execution_usage_identity_valid CHECK (((kind = ANY (ARRAY['work'::text, 'admission'::text, 'learning'::text])) AND (execution_mode = ANY (ARRAY['live'::text, 'shadow'::text])) AND ((octet_length(generation) >= 1) AND (octet_length(generation) <= 64))))
);

CREATE TABLE public.github_binding_settings (
    name text NOT NULL,
    repository_ref text NOT NULL,
    installation_id bigint NOT NULL,
    repository_id bigint NOT NULL,
    ryker_actor_id bigint NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    action_grants character varying(255)[] DEFAULT ARRAY['read'::character varying, 'review'::character varying, 'open_pull_request'::character varying, 'update_ryker_branch'::character varying, 'rerun_ci'::character varying] NOT NULL,
    granted_permissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT github_binding_permissions_valid CHECK ((jsonb_typeof(granted_permissions) = 'object'::text)),
    CONSTRAINT github_binding_settings_valid CHECK (((name ~ '^[a-z][a-z0-9_-]{0,63}$'::text) AND (installation_id > 0) AND (repository_id > 0) AND (ryker_actor_id > 0)))
);

CREATE TABLE public.github_repository_events (
    id uuid NOT NULL,
    delivery_ref text NOT NULL,
    binding_ref text NOT NULL,
    repository_id bigint NOT NULL,
    event_name text NOT NULL,
    action text,
    event_ref text NOT NULL,
    payload_digest text NOT NULL,
    disposition text DEFAULT 'received'::text NOT NULL,
    reason text,
    occurred_at timestamp without time zone NOT NULL,
    processed_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    duplicate_count integer DEFAULT 0 NOT NULL,
    last_duplicate_at timestamp without time zone,
    CONSTRAINT github_repository_duplicate_count_valid CHECK ((duplicate_count >= 0)),
    CONSTRAINT github_repository_event_valid CHECK ((((char_length(delivery_ref) >= 1) AND (char_length(delivery_ref) <= 1024)) AND ((char_length(binding_ref) >= 1) AND (char_length(binding_ref) <= 64)) AND (repository_id > 0) AND ((char_length(event_name) >= 1) AND (char_length(event_name) <= 64)) AND (payload_digest ~ '^[0-9a-f]{64}$'::text) AND (disposition = ANY (ARRAY['received'::text, 'metadata'::text, 'routed'::text, 'continued'::text, 'duplicate'::text, 'failed'::text]))))
);

CREATE TABLE public.github_settings (
    id text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    app_id bigint,
    app_slug text,
    api_url text DEFAULT 'https://api.github.com'::text NOT NULL,
    auto_add_repositories boolean DEFAULT false NOT NULL,
    bot_actor_id bigint,
    bot_login text,
    CONSTRAINT github_settings_api_url_valid CHECK (((api_url ~ '^https://[^/?#]+(:[0-9]+)?(/[^?#]*)?$'::text) AND (char_length(api_url) <= 2048))),
    CONSTRAINT github_settings_bot_valid CHECK ((((bot_actor_id IS NULL) AND (bot_login IS NULL)) OR ((bot_actor_id > 0) AND ((char_length(bot_login) >= 1) AND (char_length(bot_login) <= 256))))),
    CONSTRAINT github_settings_valid CHECK ((((app_id IS NULL) OR (app_id > 0)) AND ((app_slug IS NULL) OR ((char_length(app_slug) >= 1) AND (char_length(app_slug) <= 256))) AND ((NOT enabled) OR (app_id IS NOT NULL))))
);

CREATE TABLE public.ingress_inbox_entries (
    id uuid NOT NULL,
    dedupe_key text NOT NULL,
    event_fingerprint text NOT NULL,
    source_kind text NOT NULL,
    source_ref text NOT NULL,
    source_item_ref text,
    event_ref text NOT NULL,
    event_kind text NOT NULL,
    native_input_id text NOT NULL,
    actor_kind text NOT NULL,
    actor_ref text NOT NULL,
    destination_transport text NOT NULL,
    destination_conversation_ref text NOT NULL,
    destination_thread_ref text,
    revision bigint NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    occurred_at_source text DEFAULT 'source'::text NOT NULL,
    content text NOT NULL,
    admission_context text,
    admission_context_fingerprint text,
    status text NOT NULL,
    decision_ref text,
    decision_fingerprint text,
    decision_action text,
    decision_document text,
    attempt_count bigint DEFAULT 0 NOT NULL,
    execution_generation bigint DEFAULT 1 NOT NULL,
    validation_generation bigint DEFAULT 1 NOT NULL,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    episode_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    source_capabilities text NOT NULL,
    execution_mode text DEFAULT 'live'::text NOT NULL,
    work_policy text,
    work_policy_digest text,
    repository_ref text,
    operational_pruned_at timestamp without time zone,
    work_profile text,
    slack_audience text,
    slack_bot_user_ref text,
    source_envelope text,
    engagement_receipt text,
    CONSTRAINT ingress_inbox_admission_context_valid CHECK ((((admission_context IS NULL) AND (admission_context_fingerprint IS NULL)) OR ((admission_context IS NOT NULL) AND (char_length(admission_context_fingerprint) = 64)))),
    CONSTRAINT ingress_inbox_decision_matches_status CHECK ((((status = 'pending'::text) AND (decision_ref IS NULL) AND (decision_fingerprint IS NULL) AND (decision_action IS NULL) AND (decision_document IS NULL) AND (episode_id IS NULL)) OR ((status = 'blocked'::text) AND (decision_ref IS NULL) AND (decision_fingerprint IS NULL) AND (decision_action IS NULL) AND (decision_document IS NULL) AND (episode_id IS NULL) AND (char_length(last_error_code) > 0) AND (char_length(last_error_detail) > 0)) OR ((status = 'decided'::text) AND (char_length(decision_ref) > 0) AND (char_length(decision_fingerprint) = 64) AND (decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text, 'quick_reply'::text, 'react'::text, 'ignore'::text])) AND (decision_document IS NOT NULL) AND (((decision_action = ANY (ARRAY['quick_reply'::text, 'react'::text, 'ignore'::text])) AND (episode_id IS NULL)) OR ((decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text])) AND (episode_id IS NOT NULL)))) OR ((status = 'superseded'::text) AND (char_length(decision_ref) > 0) AND (char_length(decision_fingerprint) = 64) AND (decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text, 'react'::text, 'ignore'::text])) AND (decision_document IS NOT NULL) AND (episode_id IS NOT NULL) AND (last_error_code = 'stale_input_revision'::text) AND (char_length(last_error_detail) > 0)))),
    CONSTRAINT ingress_inbox_engagement_receipt_valid CHECK (((engagement_receipt IS NULL) OR ((octet_length(engagement_receipt) >= 2) AND (octet_length(engagement_receipt) <= 8192)))),
    CONSTRAINT ingress_inbox_event_identity_valid CHECK (((char_length(event_fingerprint) = 64) AND (revision > 0))),
    CONSTRAINT ingress_inbox_event_shape_valid CHECK (((source_kind ~ '^[a-z][a-z0-9_-]{0,63}$'::text) AND (event_kind = ANY (ARRAY['message'::text, 'edit'::text, 'delete'::text, 'event'::text])) AND (actor_kind = ANY (ARRAY['user'::text, 'app'::text, 'bot'::text, 'system'::text])))),
    CONSTRAINT ingress_inbox_execution_custody_valid CHECK (((attempt_count >= 0) AND (((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'pending'::text) AND (char_length(lease_ref) > 0) AND (char_length(lease_owner) > 0) AND (lease_expires_at IS NOT NULL))) AND ((status = 'pending'::text) OR (next_attempt_at IS NULL)))),
    CONSTRAINT ingress_inbox_execution_generation_valid CHECK ((execution_generation > 0)),
    CONSTRAINT ingress_inbox_execution_mode_valid CHECK ((execution_mode = ANY (ARRAY['live'::text, 'shadow'::text]))),
    CONSTRAINT ingress_inbox_occurrence_source_valid CHECK ((occurred_at_source = ANY (ARRAY['source'::text, 'ingress'::text]))),
    CONSTRAINT ingress_inbox_refs_not_empty CHECK (((char_length(dedupe_key) > 0) AND (char_length(event_ref) > 0) AND (char_length(source_ref) > 0) AND (char_length(native_input_id) > 0) AND (char_length(actor_ref) > 0) AND (char_length(destination_transport) > 0) AND (char_length(destination_conversation_ref) > 0))),
    CONSTRAINT ingress_inbox_slack_addressing_valid CHECK ((((slack_audience IS NULL) AND (slack_bot_user_ref IS NULL)) OR ((slack_audience IS NOT NULL) AND (slack_bot_user_ref IS NOT NULL) AND (source_kind = 'slack'::text) AND (slack_audience = ANY (ARRAY['ambient'::text, 'direct'::text, 'mention'::text])) AND ((octet_length(slack_bot_user_ref) >= 1) AND (octet_length(slack_bot_user_ref) <= 256)) AND (slack_bot_user_ref !~ '[^A-Z0-9]'::text)))),
    CONSTRAINT ingress_inbox_source_capabilities_valid CHECK (((jsonb_typeof((source_capabilities)::jsonb) = 'object'::text) AND ((NOT ((source_capabilities)::jsonb ? 'react'::text)) OR ((source_item_ref IS NOT NULL) AND (char_length(source_item_ref) > 0))) AND ((NOT ((source_capabilities)::jsonb ? 'post_slack_message'::text)) OR (((source_kind = 'slack'::text) OR ((source_kind = 'control_plane'::text) AND (source_ref = 'local'::text) AND (destination_transport = 'control_plane'::text) AND (destination_conversation_ref ~~ 'control-plane:lab:%'::text) AND (destination_thread_ref = destination_conversation_ref) AND ((((source_capabilities)::jsonb -> 'post_slack_message'::text) -> 'destination_refs'::text) = jsonb_build_array(destination_conversation_ref)))) AND (actor_kind = 'user'::text) AND (source_item_ref IS NOT NULL) AND (char_length(source_item_ref) > 0) AND (jsonb_typeof(((source_capabilities)::jsonb -> 'post_slack_message'::text)) = 'object'::text) AND (jsonb_typeof((((source_capabilities)::jsonb -> 'post_slack_message'::text) -> 'destination_refs'::text)) = 'array'::text) AND ((jsonb_array_length((((source_capabilities)::jsonb -> 'post_slack_message'::text) -> 'destination_refs'::text)) >= 1) AND (jsonb_array_length((((source_capabilities)::jsonb -> 'post_slack_message'::text) -> 'destination_refs'::text)) <= 8)))))),
    CONSTRAINT ingress_inbox_source_envelope_valid CHECK (((source_envelope IS NULL) OR ((octet_length(source_envelope) >= 2) AND (octet_length(source_envelope) <= 65536)))),
    CONSTRAINT ingress_inbox_validation_generation_valid CHECK ((validation_generation > 0)),
    CONSTRAINT ingress_inbox_work_class_profile_valid CHECK (((work_profile IS NULL) OR (((octet_length(work_profile) >= 1) AND (octet_length(work_profile) <= 65536)) AND (jsonb_typeof((work_profile)::jsonb) = 'object'::text) AND (((NOT ((work_profile)::jsonb ? 'policies'::text)) AND (((work_profile)::jsonb ?& ARRAY['class_policies'::text, 'policy'::text, 'policy_digest'::text, 'repository_ref'::text]) AND ((((((((((work_profile)::jsonb - 'authority_digest'::text) - 'emisar_connection_ref'::text) - 'environment_ref'::text) - 'parallel_goal_limit'::text) - 'class_policies'::text) - 'policy'::text) - 'policy_digest'::text) - 'repository_ref'::text) = '{}'::jsonb) AND ((((work_profile)::jsonb ->> 'policy'::text) = work_policy) AND (((work_profile)::jsonb ->> 'policy_digest'::text) = work_policy_digest) AND (NOT (((work_profile)::jsonb ->> 'repository_ref'::text) IS DISTINCT FROM repository_ref)) AND ((NOT ((work_profile)::jsonb ? 'authority_digest'::text)) OR ((jsonb_typeof(((work_profile)::jsonb -> 'authority_digest'::text)) = 'string'::text) AND (((work_profile)::jsonb ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text)))) AND (((NOT ((work_profile)::jsonb ? 'environment_ref'::text)) AND (NOT ((work_profile)::jsonb ? 'parallel_goal_limit'::text)) AND (NOT ((work_profile)::jsonb ? 'emisar_connection_ref'::text))) OR (((work_profile)::jsonb ? 'environment_ref'::text) AND ((work_profile)::jsonb ? 'parallel_goal_limit'::text) AND (jsonb_typeof(((work_profile)::jsonb -> 'environment_ref'::text)) = 'string'::text) AND (((work_profile)::jsonb ->> 'environment_ref'::text) ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text) AND (jsonb_typeof(((work_profile)::jsonb -> 'parallel_goal_limit'::text)) = 'number'::text) AND (((work_profile)::jsonb ->> 'parallel_goal_limit'::text) ~ '^[1-3]$'::text) AND ((NOT ((work_profile)::jsonb ? 'emisar_connection_ref'::text)) OR ((jsonb_typeof(((work_profile)::jsonb -> 'emisar_connection_ref'::text)) = 'string'::text) AND ((char_length(((work_profile)::jsonb ->> 'emisar_connection_ref'::text)) >= 1) AND (char_length(((work_profile)::jsonb ->> 'emisar_connection_ref'::text)) <= 64)))) AND (repository_ref IS NULL))) AND ((((work_profile)::jsonb -> 'class_policies'::text) = 'null'::jsonb) OR ((jsonb_typeof(((work_profile)::jsonb -> 'class_policies'::text)) = 'object'::text) AND (((work_profile)::jsonb -> 'class_policies'::text) ?& ARRAY['conversational'::text, 'standard'::text, 'deep'::text]) AND ((((((work_profile)::jsonb -> 'class_policies'::text) - 'conversational'::text) - 'standard'::text) - 'deep'::text) = '{}'::jsonb) AND (jsonb_typeof((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text)) = 'object'::text) AND ((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ?& ARRAY['policy'::text, 'policy_digest'::text]) AND (((((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) - 'authority_digest'::text) - 'policy'::text) - 'policy_digest'::text) = '{}'::jsonb) AND (char_length(((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ->> 'policy'::text)) > 0) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ->> 'policy_digest'::text) ~ '^[0-9a-f]{64}$'::text) AND ((NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ? 'authority_digest'::text)) OR ((jsonb_typeof(((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) -> 'authority_digest'::text)) = 'string'::text) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text))) AND (jsonb_typeof((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text)) = 'object'::text) AND ((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ?& ARRAY['policy'::text, 'policy_digest'::text]) AND (((((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) - 'authority_digest'::text) - 'policy'::text) - 'policy_digest'::text) = '{}'::jsonb) AND (char_length(((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ->> 'policy'::text)) > 0) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ->> 'policy_digest'::text) ~ '^[0-9a-f]{64}$'::text) AND ((NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ? 'authority_digest'::text)) OR ((jsonb_typeof(((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) -> 'authority_digest'::text)) = 'string'::text) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text))) AND (jsonb_typeof((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text)) = 'object'::text) AND ((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ?& ARRAY['policy'::text, 'policy_digest'::text]) AND (((((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) - 'authority_digest'::text) - 'policy'::text) - 'policy_digest'::text) = '{}'::jsonb) AND (char_length(((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ->> 'policy'::text)) > 0) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ->> 'policy_digest'::text) ~ '^[0-9a-f]{64}$'::text) AND ((NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ? 'authority_digest'::text)) OR ((jsonb_typeof(((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) -> 'authority_digest'::text)) = 'string'::text) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text))) AND (((NOT ((work_profile)::jsonb ? 'authority_digest'::text)) AND (NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ? 'authority_digest'::text)) AND (NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ? 'authority_digest'::text)) AND (NOT ((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ? 'authority_digest'::text))) OR ((jsonb_typeof(((work_profile)::jsonb -> 'authority_digest'::text)) = 'string'::text) AND (((work_profile)::jsonb ->> 'authority_digest'::text) ~ '^[0-9a-f]{64}$'::text) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'conversational'::text) ->> 'authority_digest'::text) = ((work_profile)::jsonb ->> 'authority_digest'::text)) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'standard'::text) ->> 'authority_digest'::text) = ((work_profile)::jsonb ->> 'authority_digest'::text)) AND (((((work_profile)::jsonb -> 'class_policies'::text) -> 'deep'::text) ->> 'authority_digest'::text) = ((work_profile)::jsonb ->> 'authority_digest'::text)))))))) OR (((work_profile)::jsonb ? 'policies'::text) AND (((work_profile)::jsonb ?& ARRAY['environment_ref'::text, 'parallel_goal_limit'::text, 'policies'::text, 'repositories'::text]) AND (((((((work_profile)::jsonb - 'emisar_connection_ref'::text) - 'environment_ref'::text) - 'parallel_goal_limit'::text) - 'policies'::text) - 'repositories'::text) = '{}'::jsonb) AND (((work_profile)::jsonb ? 'environment_ref'::text) AND ((work_profile)::jsonb ? 'parallel_goal_limit'::text) AND (jsonb_typeof(((work_profile)::jsonb -> 'environment_ref'::text)) = 'string'::text) AND (((work_profile)::jsonb ->> 'environment_ref'::text) ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text) AND (jsonb_typeof(((work_profile)::jsonb -> 'parallel_goal_limit'::text)) = 'number'::text) AND (((work_profile)::jsonb ->> 'parallel_goal_limit'::text) ~ '^[1-3]$'::text) AND ((NOT ((work_profile)::jsonb ? 'emisar_connection_ref'::text)) OR ((jsonb_typeof(((work_profile)::jsonb -> 'emisar_connection_ref'::text)) = 'string'::text) AND ((char_length(((work_profile)::jsonb ->> 'emisar_connection_ref'::text)) >= 1) AND (char_length(((work_profile)::jsonb ->> 'emisar_connection_ref'::text)) <= 64))))) AND (jsonb_typeof(((work_profile)::jsonb -> 'repositories'::text)) = 'array'::text) AND ((jsonb_array_length(((work_profile)::jsonb -> 'repositories'::text)) >= 1) AND (jsonb_array_length(((work_profile)::jsonb -> 'repositories'::text)) <= 33)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."repositories"[*]?(@.type() != "string" || @ == "")'::jsonpath)) AND (jsonb_typeof(((work_profile)::jsonb -> 'policies'::text)) = 'object'::text) AND (jsonb_path_query_array((work_profile)::jsonb, '$."policies".keyvalue()."key"'::jsonpath) @> ((work_profile)::jsonb -> 'repositories'::text)) AND (((work_profile)::jsonb -> 'repositories'::text) @> jsonb_path_query_array((work_profile)::jsonb, '$."policies".keyvalue()."key"'::jsonpath)) AND (jsonb_array_length(jsonb_path_query_array((work_profile)::jsonb, '$."policies".keyvalue()."key"'::jsonpath)) = jsonb_array_length(((work_profile)::jsonb -> 'repositories'::text))) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*?(((@.type() != "object" || !(exists (@."conversational"))) || !(exists (@."standard"))) || !(exists (@."deep")))'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.keyvalue()?((@."key" != "conversational" && @."key" != "standard") && @."key" != "deep")'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.*?((@.type() != "object" || !(exists (@."policy"))) || !(exists (@."policy_digest")))'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.*.keyvalue()?((@."key" != "policy" && @."key" != "policy_digest") && @."key" != "authority_digest")'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.*?(((@."policy".type() != "string" || @."policy" == "") || @."policy_digest".type() != "string") || !(@."policy_digest" like_regex "^[0-9a-f]{64}$"))'::jsonpath)) AND (NOT jsonb_path_exists((work_profile)::jsonb, '$."policies".*.*?(exists (@."authority_digest") && (@."authority_digest".type() != "string" || !(@."authority_digest" like_regex "^[0-9a-f]{64}$")))'::jsonpath)) AND ((((work_profile)::jsonb -> 'repositories'::text) ->> 0) = repository_ref) AND ((((((work_profile)::jsonb -> 'policies'::text) -> (((work_profile)::jsonb -> 'repositories'::text) ->> 0)) -> 'conversational'::text) ->> 'policy'::text) = work_policy) AND ((((((work_profile)::jsonb -> 'policies'::text) -> (((work_profile)::jsonb -> 'repositories'::text) ->> 0)) -> 'conversational'::text) ->> 'policy_digest'::text) = work_policy_digest))))))),
    CONSTRAINT ingress_inbox_work_profile_valid CHECK ((((work_policy IS NULL) AND (work_policy_digest IS NULL) AND (repository_ref IS NULL)) OR ((work_policy IS NOT NULL) AND (char_length(work_policy) > 0) AND (work_policy_digest ~ '^[0-9a-f]{64}$'::text) AND ((repository_ref IS NULL) OR (char_length(repository_ref) > 0)))))
);

CREATE TABLE public.ingress_input_artifact_references (
    input_id uuid NOT NULL,
    artifact_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.input_artifacts (
    id uuid NOT NULL,
    ref text NOT NULL,
    source_kind text NOT NULL,
    source_ref text NOT NULL,
    name text NOT NULL,
    media_type text NOT NULL,
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    data bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT input_artifact_identity_valid CHECK (((char_length(ref) >= 1) AND (char_length(ref) <= 128) AND (source_kind ~ '^[a-z0-9_.-]+$'::text) AND ((char_length(source_kind) >= 1) AND (char_length(source_kind) <= 64)) AND ((char_length(source_ref) >= 1) AND (char_length(source_ref) <= 1024)) AND ((char_length(name) >= 1) AND (char_length(name) <= 255)) AND (media_type = ANY (ARRAY['image/png'::text, 'image/jpeg'::text, 'image/webp'::text, 'image/gif'::text, 'text/plain'::text, 'text/markdown'::text, 'text/csv'::text, 'application/json'::text, 'application/yaml'::text, 'application/x-yaml'::text, 'application/pdf'::text])) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 8388608)) AND (octet_length(data) = byte_size)))
);

CREATE TABLE public.input_custody_transitions (
    id uuid NOT NULL,
    input_id uuid NOT NULL,
    sequence bigint NOT NULL,
    kind text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    generation bigint NOT NULL,
    attempt bigint NOT NULL,
    predecessor_input_id uuid,
    superseding_input_id uuid,
    owner_ref text,
    eligible_at timestamp without time zone,
    error_code text,
    detail text,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT input_custody_transition_valid CHECK (((sequence > 0) AND (generation > 0) AND (attempt >= 0) AND (kind = ANY (ARRAY['saved'::text, 'waiting_predecessor'::text, 'claimed'::text, 'reclaimed'::text, 'retry_scheduled'::text, 'blocked'::text, 'rearmed'::text, 'superseded'::text])) AND ((owner_ref IS NULL) OR ((char_length(owner_ref) >= 1) AND (char_length(owner_ref) <= 1024))) AND ((error_code IS NULL) OR ((char_length(error_code) >= 1) AND (char_length(error_code) <= 128))) AND ((detail IS NULL) OR ((char_length(detail) >= 1) AND (char_length(detail) <= 4096))) AND ((predecessor_input_id IS NULL) OR (kind = 'waiting_predecessor'::text)) AND ((kind = 'superseded'::text) OR (superseding_input_id IS NULL))))
);

CREATE TABLE public.installation_settings (
    host_ref text NOT NULL,
    singleton boolean DEFAULT true NOT NULL,
    revision bigint NOT NULL,
    applied_revision bigint DEFAULT 0 NOT NULL,
    failure_code text,
    saved_by text NOT NULL,
    saved_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT installation_settings_valid CHECK ((singleton AND ((char_length(host_ref) >= 1) AND (char_length(host_ref) <= 128)) AND (revision > 0) AND (applied_revision >= 0) AND (applied_revision <= revision) AND ((failure_code IS NULL) OR (failure_code ~ '^[a-z][a-z0-9_]{0,63}$'::text)) AND ((char_length(saved_by) >= 1) AND (char_length(saved_by) <= 256))))
);

CREATE TABLE public.integration_credential_events (
    id uuid NOT NULL,
    credential_id uuid,
    kind text NOT NULL,
    name text NOT NULL,
    action text NOT NULL,
    actor_ref text NOT NULL,
    fingerprint text,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT integration_credential_events_valid CHECK (((kind = ANY (ARRAY['slack_app'::text, 'slack_bot'::text, 'github_private_key'::text, 'github_webhook'::text, 'emisar'::text, 'webhook'::text])) AND (name ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'::text) AND (action = ANY (ARRAY['created'::text, 'replaced'::text, 'verified'::text, 'invalidated'::text, 'deleted'::text])) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 256)) AND ((fingerprint IS NULL) OR (fingerprint ~ '^[0-9a-f]{64}$'::text))))
);

CREATE TABLE public.integration_credentials (
    id uuid NOT NULL,
    kind text NOT NULL,
    name text NOT NULL,
    key_version integer NOT NULL,
    ciphertext bytea NOT NULL,
    nonce bytea NOT NULL,
    tag bytea NOT NULL,
    fingerprint text NOT NULL,
    verification_status text DEFAULT 'unverified'::text NOT NULL,
    verified_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT integration_credentials_valid CHECK (((kind = ANY (ARRAY['slack_app'::text, 'slack_bot'::text, 'github_private_key'::text, 'github_webhook'::text, 'emisar'::text, 'webhook'::text])) AND (name ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'::text) AND (key_version > 0) AND ((octet_length(ciphertext) >= 1) AND (octet_length(ciphertext) <= 1048576)) AND (octet_length(nonce) = 12) AND (octet_length(tag) = 16) AND (fingerprint ~ '^[0-9a-f]{64}$'::text) AND (verification_status = ANY (ARRAY['unverified'::text, 'verified'::text, 'invalid'::text])) AND (((verification_status = 'verified'::text) AND (verified_at IS NOT NULL)) OR ((verification_status <> 'verified'::text) AND (verified_at IS NULL)))))
);

CREATE TABLE public.learning_settings (
    id text NOT NULL,
    enabled boolean DEFAULT true NOT NULL
);

CREATE TABLE public.memory_review_items (
    id uuid NOT NULL,
    ref text NOT NULL,
    workspace_ref text NOT NULL,
    kind text NOT NULL,
    entry_refs text NOT NULL,
    reason text NOT NULL,
    source_digest text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    action text,
    reviewed_by_actor_ref text,
    reviewed_at timestamp without time zone,
    replacement text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT memory_review_item_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 1024)) AND (kind = ANY (ARRAY['stale'::text, 'duplicate'::text])) AND ((octet_length(entry_refs) >= 2) AND (octet_length(entry_refs) <= 32768)) AND ((char_length(reason) >= 1) AND (char_length(reason) <= 2000)) AND (char_length(source_digest) = 64) AND (status = ANY (ARRAY['pending'::text, 'kept'::text, 'applied'::text, 'dismissed'::text])) AND (((status = 'pending'::text) AND (action IS NULL) AND (reviewed_by_actor_ref IS NULL) AND (reviewed_at IS NULL) AND (replacement IS NULL)) OR ((status <> 'pending'::text) AND (action = ANY (ARRAY['keep'::text, 'merge'::text, 'edit'::text, 'forget'::text, 'dismiss'::text])) AND ((char_length(reviewed_by_actor_ref) >= 1) AND (char_length(reviewed_by_actor_ref) <= 1024)) AND (reviewed_at IS NOT NULL) AND ((replacement IS NULL) OR ((octet_length(replacement) >= 2) AND (octet_length(replacement) <= 32768)))))))
);

CREATE TABLE public.model_instruction_edits (
    id uuid NOT NULL,
    scope_ref text NOT NULL,
    revision bigint NOT NULL,
    actor_ref text NOT NULL,
    text_fingerprint text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT model_instruction_edit_valid CHECK (((revision > 0) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 256)) AND (text_fingerprint ~ '^[0-9a-f]{64}$'::text)))
);

CREATE TABLE public.model_instruction_settings (
    scope_ref text NOT NULL,
    text text NOT NULL,
    revision bigint NOT NULL,
    saved_by text NOT NULL,
    saved_at timestamp without time zone NOT NULL,
    CONSTRAINT model_instruction_setting_valid CHECK ((((scope_ref = 'global'::text) OR (scope_ref ~ '^slack:[A-Z0-9]+:[A-Z0-9]+$'::text)) AND (octet_length(scope_ref) <= 519) AND (octet_length(text) <= 8192) AND (revision > 0) AND ((char_length(saved_by) >= 1) AND (char_length(saved_by) <= 256))))
);

CREATE TABLE public.operational_memory_entries (
    id uuid NOT NULL,
    ref text NOT NULL,
    offer_record_id uuid,
    kind text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    workspace_ref text NOT NULL,
    scope_kind text NOT NULL,
    scope_ref text NOT NULL,
    visibility text NOT NULL,
    subject text NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    confirmed_by_actor_ref text NOT NULL,
    confirmation_ref text NOT NULL,
    confirmed_at timestamp without time zone NOT NULL,
    source_transport text NOT NULL,
    source_conversation_ref text NOT NULL,
    source_thread_ref text,
    source_message_ref text NOT NULL,
    expires_at timestamp without time zone,
    recall_count bigint DEFAULT 0 NOT NULL,
    last_recalled_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    last_reviewed_at timestamp without time zone,
    edited_at timestamp without time zone,
    edited_by_actor_ref text,
    edit_review_ref text,
    answer_provenance text,
    CONSTRAINT operational_memory_edit_provenance_valid CHECK ((((edited_at IS NULL) AND (edited_by_actor_ref IS NULL) AND (edit_review_ref IS NULL)) OR ((edited_at IS NOT NULL) AND ((char_length(edited_by_actor_ref) >= 1) AND (char_length(edited_by_actor_ref) <= 1024)) AND ((char_length(edit_review_ref) >= 1) AND (char_length(edit_review_ref) <= 256))))),
    CONSTRAINT operational_memory_entry_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND (kind = ANY (ARRAY['alias'::text, 'repository_binding'::text, 'evidence_route'::text, 'entity_relationship'::text])) AND (status = ANY (ARRAY['active'::text, 'superseded'::text, 'deleted'::text, 'expired'::text])) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 1024)) AND ((char_length(scope_ref) >= 1) AND (char_length(scope_ref) <= 1024)) AND ((char_length(subject) >= 1) AND (char_length(subject) <= 120)) AND ((octet_length(payload) >= 2) AND (octet_length(payload) <= 32768)) AND (char_length(payload_fingerprint) = 64) AND ((char_length(confirmed_by_actor_ref) >= 1) AND (char_length(confirmed_by_actor_ref) <= 1024)) AND ((char_length(confirmation_ref) >= 1) AND (char_length(confirmation_ref) <= 1024)) AND ((char_length(source_transport) >= 1) AND (char_length(source_transport) <= 1024)) AND ((char_length(source_conversation_ref) >= 1) AND (char_length(source_conversation_ref) <= 1024)) AND ((source_thread_ref IS NULL) OR ((char_length(source_thread_ref) >= 1) AND (char_length(source_thread_ref) <= 1024))) AND ((char_length(source_message_ref) >= 1) AND (char_length(source_message_ref) <= 1024)) AND (recall_count >= 0) AND (((scope_kind = 'global'::text) AND (visibility = 'global'::text) AND (workspace_ref = 'installation'::text) AND (scope_ref ~ '^installation:[a-f0-9]{64}$'::text) AND (expires_at IS NULL) AND (answer_provenance IS NOT NULL)) OR ((scope_kind = ANY (ARRAY['conversation'::text, 'repository'::text, 'workspace'::text])) AND (visibility = ANY (ARRAY['conversation'::text, 'workspace'::text])) AND (expires_at IS NOT NULL) AND (expires_at > confirmed_at) AND (answer_provenance IS NULL) AND (((scope_kind = 'conversation'::text) AND (visibility = 'conversation'::text)) OR (scope_kind = 'repository'::text) OR ((scope_kind = 'workspace'::text) AND (visibility = 'workspace'::text))))))),
    CONSTRAINT operational_memory_provenance_valid CHECK ((((offer_record_id IS NOT NULL) AND (answer_provenance IS NULL)) OR ((offer_record_id IS NULL) AND (answer_provenance IS NOT NULL) AND ((octet_length(answer_provenance) >= 2) AND (octet_length(answer_provenance) <= 8192)) AND (scope_kind = 'global'::text))))
);

CREATE TABLE public.operator_behaviors (
    id uuid NOT NULL,
    ref text NOT NULL,
    offer_record_id uuid NOT NULL,
    kind text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    workspace_ref text NOT NULL,
    scope_kind text NOT NULL,
    scope_ref text NOT NULL,
    identity_key text NOT NULL,
    payload text NOT NULL,
    confirmed_by_actor_ref text NOT NULL,
    confirmation_ref text NOT NULL,
    confirmed_at timestamp without time zone NOT NULL,
    source_transport text NOT NULL,
    source_conversation_ref text NOT NULL,
    source_thread_ref text,
    source_message_ref text NOT NULL,
    expires_at timestamp without time zone,
    use_count bigint DEFAULT 0 NOT NULL,
    last_used_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    last_reviewed_at timestamp without time zone,
    edited_at timestamp without time zone,
    edited_by_actor_ref text,
    edit_review_ref text,
    CONSTRAINT operator_behavior_edit_provenance_valid CHECK ((((edited_at IS NULL) AND (edited_by_actor_ref IS NULL) AND (edit_review_ref IS NULL)) OR ((edited_at IS NOT NULL) AND ((char_length(edited_by_actor_ref) >= 1) AND (char_length(edited_by_actor_ref) <= 1024)) AND ((char_length(edit_review_ref) >= 1) AND (char_length(edit_review_ref) <= 256))))),
    CONSTRAINT operator_behavior_revision_valid CHECK ((revision > 0)),
    CONSTRAINT operator_behavior_valid CHECK (((char_length(ref) >= 1) AND (char_length(ref) <= 256) AND (kind = ANY (ARRAY['preference'::text, 'guidance'::text, 'standing_assignment'::text])) AND (status = ANY (ARRAY['active'::text, 'disabled'::text, 'superseded'::text, 'deleted'::text, 'expired'::text])) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 1024)) AND (scope_kind = ANY (ARRAY['workspace'::text, 'conversation'::text, 'repository'::text, 'operator'::text])) AND ((char_length(scope_ref) >= 1) AND (char_length(scope_ref) <= 1024)) AND ((char_length(identity_key) >= 1) AND (char_length(identity_key) <= 256)) AND ((octet_length(payload) >= 2) AND (octet_length(payload) <= 32768)) AND ((char_length(confirmed_by_actor_ref) >= 1) AND (char_length(confirmed_by_actor_ref) <= 1024)) AND ((char_length(confirmation_ref) >= 1) AND (char_length(confirmation_ref) <= 1024)) AND ((char_length(source_transport) >= 1) AND (char_length(source_transport) <= 1024)) AND ((char_length(source_conversation_ref) >= 1) AND (char_length(source_conversation_ref) <= 1024)) AND ((source_thread_ref IS NULL) OR ((char_length(source_thread_ref) >= 1) AND (char_length(source_thread_ref) <= 1024))) AND ((char_length(source_message_ref) >= 1) AND (char_length(source_message_ref) <= 1024)) AND ((expires_at IS NULL) OR (expires_at > confirmed_at)) AND (use_count >= 0)))
);

CREATE TABLE public.platform_actions (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    action_ref text NOT NULL,
    host_slot text NOT NULL,
    tool text NOT NULL,
    kind text NOT NULL,
    transport text NOT NULL,
    conversation_ref text NOT NULL,
    thread_ref text,
    source_item_ref text,
    document text NOT NULL,
    intent_fingerprint text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt_count bigint DEFAULT 0 NOT NULL,
    retry_generation bigint DEFAULT 0 NOT NULL,
    lease_ref uuid,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    external_receipt text,
    external_receipt_fingerprint text,
    delivered_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT platform_actions_custody_valid CHECK (((status = ANY (ARRAY['pending'::text, 'blocked'::text, 'delivered'::text])) AND (((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'pending'::text) AND (lease_ref IS NOT NULL) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL))) AND ((status = 'pending'::text) OR (next_attempt_at IS NULL)) AND ((status <> 'blocked'::text) OR ((char_length(last_error_code) >= 1) AND (char_length(last_error_code) <= 128) AND ((char_length(last_error_detail) >= 1) AND (char_length(last_error_detail) <= 4096)))) AND (((status = ANY (ARRAY['pending'::text, 'blocked'::text])) AND (external_receipt IS NULL) AND (external_receipt_fingerprint IS NULL) AND (delivered_at IS NULL)) OR ((status = 'delivered'::text) AND (external_receipt IS NOT NULL) AND (char_length(external_receipt_fingerprint) = 64) AND (delivered_at IS NOT NULL))))),
    CONSTRAINT platform_actions_document_valid CHECK (((jsonb_typeof((document)::jsonb) = 'object'::text) AND (((kind = 'message'::text) AND (source_item_ref IS NULL) AND ((document)::jsonb ? 'message'::text) AND (((document)::jsonb - 'message'::text) = '{}'::jsonb) AND (jsonb_typeof(((document)::jsonb -> 'message'::text)) = 'string'::text) AND ((char_length(((document)::jsonb ->> 'message'::text)) >= 1) AND (char_length(((document)::jsonb ->> 'message'::text)) <= 20000))) OR ((kind = 'reaction'::text) AND (source_item_ref IS NOT NULL) AND ((document)::jsonb ? 'emoji_name'::text) AND ((document)::jsonb ? 'action'::text) AND ((((document)::jsonb - 'emoji_name'::text) - 'action'::text) = '{}'::jsonb) AND (jsonb_typeof(((document)::jsonb -> 'emoji_name'::text)) = 'string'::text) AND ((char_length(((document)::jsonb ->> 'emoji_name'::text)) >= 1) AND (char_length(((document)::jsonb ->> 'emoji_name'::text)) <= 100)) AND (((document)::jsonb ->> 'action'::text) = ANY (ARRAY['add'::text, 'remove'::text])))))),
    CONSTRAINT platform_actions_identity_valid CHECK (((char_length(action_ref) >= 1) AND (char_length(action_ref) <= 256) AND ((char_length(host_slot) >= 1) AND (char_length(host_slot) <= 256)) AND (tool = ANY (ARRAY['set_slack_reaction'::text, 'post_slack_message'::text, 'set_github_reaction'::text])) AND (kind = ANY (ARRAY['message'::text, 'reaction'::text])) AND ((char_length(transport) >= 1) AND (char_length(transport) <= 1024)) AND ((char_length(conversation_ref) >= 1) AND (char_length(conversation_ref) <= 1024)) AND ((thread_ref IS NULL) OR ((char_length(thread_ref) >= 1) AND (char_length(thread_ref) <= 1024))) AND ((source_item_ref IS NULL) OR ((char_length(source_item_ref) >= 1) AND (char_length(source_item_ref) <= 1024))) AND (char_length(intent_fingerprint) = 64) AND (attempt_count >= 0) AND (retry_generation >= 0)))
);

CREATE TABLE public.policy_bindings (
    id uuid NOT NULL,
    purpose text NOT NULL,
    scope_kind text NOT NULL,
    scope_ref text NOT NULL,
    policy_name text NOT NULL,
    policy_digest text NOT NULL,
    authority_digest text,
    verified_by text NOT NULL,
    verified_worker_ref text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    repository_ref text DEFAULT ''::text NOT NULL,
    CONSTRAINT policy_binding_repository_valid CHECK ((((scope_kind = 'environment'::text) AND (repository_ref ~ '^[a-z0-9][a-z0-9_-]{0,63}$'::text)) OR ((scope_kind <> 'environment'::text) AND (repository_ref = ''::text)))),
    CONSTRAINT policy_binding_valid CHECK (((purpose = ANY (ARRAY['admission'::text, 'learning'::text, 'incident'::text, 'schedule_read_only'::text, 'schedule_governed'::text, 'conversational'::text, 'standard'::text, 'deep'::text, 'contributor'::text, 'schedule'::text])) AND (scope_kind = ANY (ARRAY['installation'::text, 'repository'::text, 'environment'::text])) AND (((scope_kind = 'installation'::text) AND (scope_ref = ''::text)) OR ((scope_kind = 'repository'::text) AND (scope_ref ~ '^[a-z][a-z0-9_-]{0,63}$'::text)) OR ((scope_kind = 'environment'::text) AND (scope_ref ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text))) AND (((purpose = ANY (ARRAY['admission'::text, 'conversational'::text, 'learning'::text, 'incident'::text, 'schedule_read_only'::text, 'schedule_governed'::text])) AND (scope_kind = 'installation'::text)) OR ((purpose = ANY (ARRAY['conversational'::text, 'standard'::text, 'deep'::text, 'contributor'::text])) AND (scope_kind <> 'installation'::text)) OR ((purpose = 'schedule'::text) AND (scope_kind = 'repository'::text))) AND ((char_length(policy_name) >= 1) AND (char_length(policy_name) <= 256)) AND (policy_digest ~ '^[0-9a-f]{64}$'::text) AND ((authority_digest IS NULL) OR (authority_digest ~ '^[0-9a-f]{64}$'::text)) AND (verified_by = ANY (ARRAY['worker'::text, 'import'::text])) AND ((verified_worker_ref IS NULL) OR ((char_length(verified_worker_ref) >= 1) AND (char_length(verified_worker_ref) <= 256)))))
);

CREATE TABLE public.pricing_rates (
    id uuid NOT NULL,
    execution_target text NOT NULL,
    input_usd_per_million numeric NOT NULL,
    cached_input_usd_per_million numeric NOT NULL,
    output_usd_per_million numeric NOT NULL,
    reasoning_usd_per_million numeric,
    effective_from date NOT NULL,
    revision bigint NOT NULL,
    provenance text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT pricing_rate_valid CHECK ((((char_length(execution_target) >= 1) AND (char_length(execution_target) <= 256)) AND (input_usd_per_million >= (0)::numeric) AND (cached_input_usd_per_million >= (0)::numeric) AND (output_usd_per_million >= (0)::numeric) AND ((reasoning_usd_per_million IS NULL) OR (reasoning_usd_per_million >= (0)::numeric)) AND (input_usd_per_million <= (100000)::numeric) AND (cached_input_usd_per_million <= (100000)::numeric) AND (output_usd_per_million <= (100000)::numeric) AND (revision > 0) AND ((char_length(provenance) >= 1) AND (char_length(provenance) <= 1024))))
);

CREATE TABLE public.publication_settings (
    id text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    branch_prefix text DEFAULT 'ryker'::text NOT NULL,
    commit_name text DEFAULT 'Ryker'::text NOT NULL,
    commit_email text DEFAULT 'ryker@localhost'::text NOT NULL,
    CONSTRAINT publication_settings_valid CHECK ((((char_length(branch_prefix) >= 1) AND (char_length(branch_prefix) <= 240)) AND ((char_length(commit_name) >= 1) AND (char_length(commit_name) <= 256)) AND ((char_length(commit_email) >= 3) AND (char_length(commit_email) <= 320))))
);

CREATE TABLE public.report_settings (
    id text NOT NULL,
    weekly_self_report_enabled boolean DEFAULT false NOT NULL,
    channel_ref text,
    weekday integer DEFAULT 1 NOT NULL,
    local_time time(0) without time zone DEFAULT '09:00:00'::time without time zone NOT NULL,
    timezone text DEFAULT 'Etc/UTC'::text NOT NULL,
    CONSTRAINT report_settings_valid CHECK ((((weekday >= 1) AND (weekday <= 7)) AND ((char_length(timezone) >= 1) AND (char_length(timezone) <= 64)) AND ((channel_ref IS NULL) OR (channel_ref ~ '^[A-Z0-9]{1,255}$'::text)) AND ((NOT weekly_self_report_enabled) OR (channel_ref IS NOT NULL))))
);

CREATE TABLE public.repository_settings (
    ref text NOT NULL,
    display_name text,
    description text,
    github_repository text,
    base_branch text DEFAULT 'main'::text NOT NULL,
    publication_checkout_path text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    github_access text DEFAULT 'available'::text NOT NULL,
    onboarding_state text DEFAULT 'pending'::text NOT NULL,
    onboarding_error text,
    source_commit text,
    knowledge_pull_request_url text,
    last_github_event_at timestamp without time zone,
    knowledge_content text,
    knowledge_status text,
    knowledge_source_commit text,
    knowledge_sha256 text,
    materialized_at timestamp without time zone,
    CONSTRAINT repository_github_state_valid CHECK (((github_access = ANY (ARRAY['available'::text, 'suspended'::text, 'removed'::text])) AND (onboarding_state = ANY (ARRAY['pending'::text, 'cloning'::text, 'scanning'::text, 'publishing'::text, 'ready'::text, 'blocked'::text])))),
    CONSTRAINT repository_knowledge_valid CHECK ((((knowledge_status IS NULL) AND (knowledge_content IS NULL) AND (knowledge_source_commit IS NULL) AND (knowledge_sha256 IS NULL)) OR ((knowledge_status = ANY (ARRAY['accepted'::text, 'proposed'::text])) AND (knowledge_content IS NOT NULL) AND (knowledge_source_commit ~ '^[0-9a-f]{40}$'::text) AND (knowledge_sha256 ~ '^[0-9a-f]{64}$'::text)))),
    CONSTRAINT repository_settings_valid CHECK (((ref ~ '^[a-z0-9][a-z0-9_-]{0,63}$'::text) AND ((display_name IS NULL) OR ((char_length(display_name) >= 1) AND (char_length(display_name) <= 120))) AND ((description IS NULL) OR ((char_length(description) >= 1) AND (char_length(description) <= 1000))) AND ((github_repository IS NULL) OR (github_repository ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'::text)) AND ((char_length(base_branch) >= 1) AND (char_length(base_branch) <= 240)) AND ((publication_checkout_path IS NULL) OR (publication_checkout_path ~ '^/'::text))))
);

CREATE TABLE public.retention_operator_actions (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    action_ref text NOT NULL,
    request_fingerprint text NOT NULL,
    actor_ref text NOT NULL,
    action text NOT NULL,
    previous_status text NOT NULL,
    result_status text NOT NULL,
    previous_plan_fingerprint text,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT retention_operator_action_valid CHECK (((char_length(action_ref) >= 1) AND (char_length(action_ref) <= 1024) AND (char_length(request_fingerprint) = 64) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (action = ANY (ARRAY['rearm'::text, 'discard_unmerged'::text])) AND (previous_status = ANY (ARRAY['blocked'::text, 'retained'::text])) AND (result_status = ANY (ARRAY['close_pending'::text, 'plan_pending'::text, 'discard_pending'::text])) AND ((previous_plan_fingerprint IS NULL) OR (char_length(previous_plan_fingerprint) = 64))))
);

CREATE TABLE public.retention_settings (
    id text NOT NULL,
    operational_data_seconds bigint NOT NULL,
    conversation_memory_seconds bigint NOT NULL,
    closed_work_seconds bigint NOT NULL,
    episode_history_seconds bigint NOT NULL,
    audit_data_seconds bigint NOT NULL,
    CONSTRAINT retention_settings_valid CHECK ((((operational_data_seconds >= 60) AND (operational_data_seconds <= 315360000)) AND ((conversation_memory_seconds >= 60) AND (conversation_memory_seconds <= 315360000)) AND ((closed_work_seconds >= 60) AND (closed_work_seconds <= 315360000)) AND ((episode_history_seconds >= 60) AND (episode_history_seconds <= 315360000)) AND ((audit_data_seconds >= 60) AND (audit_data_seconds <= 315360000)) AND (operational_data_seconds <= closed_work_seconds) AND (closed_work_seconds <= episode_history_seconds) AND (episode_history_seconds <= audit_data_seconds) AND (operational_data_seconds <= conversation_memory_seconds)))
);

CREATE TABLE public.ryker_operator_actions (
    id uuid NOT NULL,
    action_ref text NOT NULL,
    request_fingerprint text NOT NULL,
    actor_ref text NOT NULL,
    action text NOT NULL,
    kind text NOT NULL,
    resource_ref text NOT NULL,
    previous text NOT NULL,
    outcome text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT ryker_operator_action_valid CHECK ((((char_length(action_ref) >= 1) AND (char_length(action_ref) <= 1024)) AND (char_length(request_fingerprint) = 64) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (action = ANY (ARRAY['retry'::text, 'replay'::text, 'update'::text, 'discard'::text])) AND ((char_length(kind) >= 1) AND (char_length(kind) <= 64)) AND ((char_length(resource_ref) >= 1) AND (char_length(resource_ref) <= 1024)) AND (jsonb_typeof((previous)::jsonb) = 'object'::text) AND (jsonb_typeof((outcome)::jsonb) = 'object'::text)))
);

CREATE TABLE public.ryker_runtime_progress (
    lane text NOT NULL,
    outcome text NOT NULL,
    cycle_count bigint DEFAULT 0 NOT NULL,
    observed_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT ryker_runtime_progress_identity_valid CHECK ((((char_length(lane) >= 1) AND (char_length(lane) <= 64)) AND (lane ~ '^[a-z][a-z0-9_]*$'::text) AND (outcome = ANY (ARRAY['cycle'::text, 'error'::text])) AND (cycle_count > 0)))
);

CREATE TABLE public.settings_edits (
    id uuid NOT NULL,
    domain text NOT NULL,
    revision bigint NOT NULL,
    actor_ref text NOT NULL,
    fingerprint text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT settings_edit_valid CHECK (((domain = ANY (ARRAY['installation'::text, 'retention'::text, 'slack'::text, 'github'::text, 'publication'::text, 'emisar'::text, 'report'::text, 'learning'::text, 'repositories'::text, 'policies'::text, 'webhooks'::text, 'pricing'::text, 'import'::text, 'work'::text, 'environments'::text])) AND (revision > 0) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 256)) AND (fingerprint ~ '^[0-9a-f]{64}$'::text)))
);

CREATE TABLE public.settings_import_receipts (
    id uuid NOT NULL,
    source_fingerprint text NOT NULL,
    plan_fingerprint text NOT NULL,
    host_ref text NOT NULL,
    revision bigint NOT NULL,
    actor_ref text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT settings_import_receipt_valid CHECK (((source_fingerprint ~ '^[0-9a-f]{64}$'::text) AND (plan_fingerprint ~ '^[0-9a-f]{64}$'::text) AND ((char_length(host_ref) >= 1) AND (char_length(host_ref) <= 128)) AND (revision > 0) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 256))))
);

CREATE TABLE public.slack_channel_configurations (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    participation text,
    environment_ref text,
    alert_policy text NOT NULL,
    invite_user_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    invite_user_group_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    actor_ref text,
    revision bigint DEFAULT 1 NOT NULL,
    saved_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    welcome_message_ref text,
    CONSTRAINT slack_channel_configuration_valid CHECK ((((participation IS NULL) OR (participation = ANY (ARRAY['mentions'::text, 'proactive'::text, 'shadow'::text]))) AND (alert_policy = ANY (ARRAY['reply'::text, 'offer'::text, 'automatic'::text])) AND (revision > 0) AND ((actor_ref IS NULL) OR (char_length(actor_ref) > 0)) AND ((welcome_message_ref IS NULL) OR (char_length(welcome_message_ref) > 0))))
);

CREATE TABLE public.slack_channel_membership_events (
    id uuid NOT NULL,
    membership_id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    event_ref text NOT NULL,
    event_fingerprint text NOT NULL,
    actor_ref text,
    kind text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_channel_membership_event_valid CHECK (((kind = ANY (ARRAY['joined'::text, 'left'::text, 'deleted'::text])) AND (char_length(event_fingerprint) = 64)))
);

CREATE TABLE public.slack_channel_memberships (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    status text NOT NULL,
    generation bigint DEFAULT 1 NOT NULL,
    joined_at timestamp without time zone,
    left_at timestamp without time zone,
    deleted_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    external_shared boolean,
    private boolean,
    CONSTRAINT slack_channel_membership_valid CHECK (((generation > 0) AND (status = ANY (ARRAY['joined'::text, 'left'::text, 'deleted'::text])) AND (((status = 'joined'::text) AND (joined_at IS NOT NULL) AND (left_at IS NULL) AND (deleted_at IS NULL)) OR ((status = 'left'::text) AND (joined_at IS NOT NULL) AND (left_at IS NOT NULL) AND (deleted_at IS NULL)) OR ((status = 'deleted'::text) AND (deleted_at IS NOT NULL)))))
);

CREATE TABLE public.slack_channel_setting_audit (
    id uuid NOT NULL,
    event_ref text NOT NULL,
    request_fingerprint text NOT NULL,
    workspace_ref text NOT NULL,
    conversation_ref text NOT NULL,
    actor_ref text NOT NULL,
    outcome text NOT NULL,
    detail text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_channel_setting_audit_valid CHECK (((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024) AND (char_length(request_fingerprint) = 64) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(conversation_ref) >= 1) AND (char_length(conversation_ref) <= 1024)) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (outcome = 'updated'::text) AND ((octet_length(detail) >= 2) AND (octet_length(detail) <= 4096))))
);

CREATE TABLE public.slack_configuration_actions (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    event_ref text NOT NULL,
    event_fingerprint text NOT NULL,
    actor_ref text NOT NULL,
    action text NOT NULL,
    outcome text NOT NULL,
    session_revision bigint NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_configuration_action_valid CHECK (((char_length(event_fingerprint) = 64) AND (session_revision > 0) AND (char_length(outcome) > 0)))
);

CREATE TABLE public.slack_configuration_sessions (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    membership_generation bigint NOT NULL,
    start_event_ref text NOT NULL,
    start_fingerprint text NOT NULL,
    initiator_ref text,
    step text NOT NULL,
    status text NOT NULL,
    draft text NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    root_message_ref text,
    response_thread_ref text,
    current_message_ref text,
    expires_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_configuration_session_valid CHECK (((step = ANY (ARRAY['participation'::text, 'environment'::text, 'alerts'::text, 'audience'::text, 'confirm'::text])) AND (status = ANY (ARRAY['asking'::text, 'confirming'::text, 'saved'::text, 'cancelled'::text, 'expired'::text])) AND (membership_generation > 0) AND (revision > 0) AND (char_length(start_fingerprint) = 64) AND (jsonb_typeof((draft)::jsonb) = 'object'::text) AND ((status <> 'confirming'::text) OR (step = 'confirm'::text))))
);

CREATE TABLE public.slack_incident_room_lifecycle_events (
    id uuid NOT NULL,
    room_id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    event_ref text NOT NULL,
    event_fingerprint text NOT NULL,
    kind text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_incident_room_lifecycle_event_valid CHECK (((kind = ANY (ARRAY['joined'::text, 'left'::text, 'archived'::text, 'unarchived'::text, 'deleted'::text, 'observed_active'::text, 'observed_archived'::text, 'observed_unavailable'::text])) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256)) AND ((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024)) AND (char_length(event_fingerprint) = 64)))
);

CREATE TABLE public.slack_incident_rooms (
    id uuid NOT NULL,
    ref text NOT NULL,
    record_id uuid NOT NULL,
    source_episode_id uuid NOT NULL,
    episode_id uuid,
    status text NOT NULL,
    workspace_ref text NOT NULL,
    bot_user_ref text NOT NULL,
    source_channel_ref text NOT NULL,
    source_thread_ref text,
    source_message_ref text NOT NULL,
    requested_by_actor_ref text NOT NULL,
    confirmation_ref text NOT NULL,
    requested_at timestamp without time zone NOT NULL,
    policy text NOT NULL,
    policy_digest text NOT NULL,
    repository_ref text NOT NULL,
    title text NOT NULL,
    prompt text NOT NULL,
    channel_name text NOT NULL,
    private boolean NOT NULL,
    channel_ref text,
    channel_state text DEFAULT 'pending'::text NOT NULL,
    reconciled_channel_state text DEFAULT 'pending'::text NOT NULL,
    channel_state_event_ref text,
    channel_state_changed_at timestamp without time zone,
    channel_checked_at timestamp without time zone,
    root_message_ref text,
    root_card_fingerprint text,
    root_card_ui_revision bigint DEFAULT 0 NOT NULL,
    root_card_checked_at timestamp without time zone,
    handoff_message_ref text,
    topic text NOT NULL,
    invite_user_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    invite_user_group_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    audience_prepared_at timestamp without time zone,
    topic_prepared_at timestamp without time zone,
    root_pinned_at timestamp without time zone,
    attempt_count bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp without time zone,
    lease_owner text,
    lease_ref uuid,
    lease_expires_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    repository_context text,
    environment_ref text,
    CONSTRAINT slack_incident_room_repository_context_valid CHECK (((repository_context IS NULL) OR (((octet_length(repository_context) >= 1) AND (octet_length(repository_context) <= 16384)) AND (jsonb_typeof((repository_context)::jsonb) = 'object'::text) AND ((repository_context)::jsonb ?& ARRAY['context_ref'::text, 'parallel_goal_limit'::text, 'primary_repository'::text, 'read_only_repositories'::text]) AND ((((((repository_context)::jsonb - 'context_ref'::text) - 'parallel_goal_limit'::text) - 'primary_repository'::text) - 'read_only_repositories'::text) = '{}'::jsonb) AND (jsonb_typeof(((repository_context)::jsonb -> 'context_ref'::text)) = 'string'::text) AND ((char_length(((repository_context)::jsonb ->> 'context_ref'::text)) >= 1) AND (char_length(((repository_context)::jsonb ->> 'context_ref'::text)) <= 256)) AND (jsonb_typeof(((repository_context)::jsonb -> 'primary_repository'::text)) = 'string'::text) AND (((repository_context)::jsonb ->> 'primary_repository'::text) = repository_ref) AND (jsonb_typeof(((repository_context)::jsonb -> 'parallel_goal_limit'::text)) = 'number'::text) AND (((repository_context)::jsonb ->> 'parallel_goal_limit'::text) ~ '^[1-3]$'::text) AND (jsonb_typeof(((repository_context)::jsonb -> 'read_only_repositories'::text)) = 'array'::text) AND (jsonb_array_length(((repository_context)::jsonb -> 'read_only_repositories'::text)) <= 32) AND (NOT (((repository_context)::jsonb -> 'read_only_repositories'::text) @> jsonb_build_array(repository_ref)))))),
    CONSTRAINT slack_incident_room_valid CHECK (((status = ANY (ARRAY['requested'::text, 'ready'::text, 'blocked'::text, 'closed'::text])) AND (channel_state = ANY (ARRAY['pending'::text, 'active'::text, 'archived'::text, 'deleted'::text, 'unavailable'::text])) AND (reconciled_channel_state = ANY (ARRAY['pending'::text, 'active'::text, 'archived'::text, 'deleted'::text, 'unavailable'::text])) AND ((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(policy) >= 1) AND (char_length(policy) <= 256)) AND (char_length(policy_digest) = 64) AND ((char_length(repository_ref) >= 1) AND (char_length(repository_ref) <= 256)) AND ((char_length(title) >= 1) AND (char_length(title) <= 200)) AND ((char_length(prompt) >= 1) AND (char_length(prompt) <= 4000)) AND ((char_length(channel_name) >= 1) AND (char_length(channel_name) <= 80)) AND ((char_length(topic) >= 1) AND (char_length(topic) <= 250)) AND (attempt_count >= 0) AND (root_card_ui_revision >= 0) AND ((root_card_fingerprint IS NULL) OR (char_length(root_card_fingerprint) = 64)) AND (((lease_owner IS NULL) AND (lease_ref IS NULL) AND (lease_expires_at IS NULL)) OR ((status = ANY (ARRAY['requested'::text, 'ready'::text])) AND (char_length(lease_owner) > 0) AND (lease_ref IS NOT NULL) AND (lease_expires_at IS NOT NULL))) AND ((status = ANY (ARRAY['requested'::text, 'ready'::text])) OR (next_attempt_at IS NULL)) AND (((channel_ref IS NULL) AND (channel_state = 'pending'::text)) OR ((channel_ref IS NOT NULL) AND (channel_state <> 'pending'::text))) AND ((status <> 'ready'::text) OR ((episode_id IS NOT NULL) AND (channel_ref IS NOT NULL) AND (root_message_ref IS NOT NULL) AND (root_card_fingerprint IS NOT NULL) AND (root_card_ui_revision > 0) AND (handoff_message_ref IS NOT NULL) AND (audience_prepared_at IS NOT NULL) AND (topic_prepared_at IS NOT NULL) AND (root_pinned_at IS NOT NULL))))),
    CONSTRAINT slack_incident_rooms_environment_valid CHECK (((environment_ref IS NULL) OR (environment_ref ~ '^[a-z0-9][a-z0-9-]{0,63}$'::text)))
);

CREATE TABLE public.slack_interaction_audit (
    id uuid NOT NULL,
    event_ref text NOT NULL,
    request_fingerprint text NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    thread_ref text,
    message_ref text NOT NULL,
    actor_ref text NOT NULL,
    action_id text NOT NULL,
    action_value_digest text NOT NULL,
    outcome text NOT NULL,
    repaint_status text NOT NULL,
    attempt_count bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp without time zone,
    lease_owner text,
    lease_ref uuid,
    lease_expires_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    occurred_at timestamp without time zone NOT NULL,
    repainted_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_interaction_audit_valid CHECK ((((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024)) AND (char_length(request_fingerprint) = 64) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256)) AND ((thread_ref IS NULL) OR ((char_length(thread_ref) >= 1) AND (char_length(thread_ref) <= 1024))) AND ((char_length(message_ref) >= 1) AND (char_length(message_ref) <= 1024)) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND ((char_length(action_id) >= 1) AND (char_length(action_id) <= 256)) AND (char_length(action_value_digest) = 64) AND (repaint_status = ANY (ARRAY['none'::text, 'pending'::text, 'settled'::text, 'blocked'::text])) AND (((outcome = 'denied'::text) AND (repaint_status = 'none'::text)) OR ((outcome = 'invalid'::text) OR ((outcome = 'confirmed'::text) AND (repaint_status <> 'none'::text)))) AND (attempt_count >= 0) AND (((lease_owner IS NULL) AND (lease_ref IS NULL) AND (lease_expires_at IS NULL)) OR (((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_ref IS NOT NULL) AND (lease_expires_at IS NOT NULL))) AND ((repainted_at IS NULL) OR (repaint_status = 'settled'::text))))
);

CREATE TABLE public.slack_settings (
    id text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    workspace_ref text,
    bot_ref text,
    bot_user_ref text,
    channel_prefix text DEFAULT 'ems'::text NOT NULL,
    incident_private boolean DEFAULT true NOT NULL,
    default_participation text DEFAULT 'mentions'::text NOT NULL,
    operators text[] DEFAULT ARRAY[]::text[] NOT NULL,
    workspace_url text,
    workspace_name character varying(255),
    bot_name character varying(255),
    CONSTRAINT slack_settings_bot_name_length CHECK (((bot_name IS NULL) OR ((char_length((bot_name)::text) >= 1) AND (char_length((bot_name)::text) <= 256)))),
    CONSTRAINT slack_settings_workspace_name_length CHECK (((workspace_name IS NULL) OR ((char_length((workspace_name)::text) >= 1) AND (char_length((workspace_name)::text) <= 256)))),
    CONSTRAINT slack_settings_workspace_url_valid CHECK (((workspace_url IS NULL) OR ((workspace_url ~ '^https://[a-z0-9-]{1,64}\.slack\.com/?$'::text) AND (char_length(workspace_url) <= 256))))
);

CREATE TABLE public.slack_source_audits (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text,
    requester_ref text NOT NULL,
    tool text NOT NULL,
    capability text NOT NULL,
    request_fingerprint text NOT NULL,
    source_fingerprint text,
    range_fingerprint text NOT NULL,
    authorized boolean NOT NULL,
    result_count bigint NOT NULL,
    complete boolean NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_source_audits_valid CHECK (((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256) AND ((channel_ref IS NULL) OR ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256))) AND ((char_length(requester_ref) >= 1) AND (char_length(requester_ref) <= 1024)) AND (tool = ANY (ARRAY['list_slack_channels'::text, 'search_slack'::text, 'read_slack_source'::text])) AND ((char_length(capability) >= 1) AND (char_length(capability) <= 128)) AND (char_length(request_fingerprint) = 64) AND ((source_fingerprint IS NULL) OR (char_length(source_fingerprint) = 64)) AND (char_length(range_fingerprint) = 64) AND ((result_count >= 0) AND (result_count <= 10000))))
);

CREATE TABLE public.slack_task_cards (
    id uuid NOT NULL,
    ref text NOT NULL,
    record_id uuid NOT NULL,
    episode_id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    thread_ref text NOT NULL,
    message_ref text NOT NULL,
    card_fingerprint text,
    rendered_publication_offer_ref text,
    card_ui_revision bigint DEFAULT 0 NOT NULL,
    card_checked_at timestamp without time zone,
    attempt_count bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp without time zone,
    lease_owner text,
    lease_ref uuid,
    lease_expires_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    CONSTRAINT slack_task_card_status_valid CHECK (((status = ANY (ARRAY['active'::text, 'blocked'::text])) AND ((status <> 'blocked'::text) OR ((last_error_code IS NOT NULL) AND (next_attempt_at IS NULL) AND (lease_ref IS NULL))))),
    CONSTRAINT slack_task_card_valid CHECK (((char_length(ref) >= 1) AND (char_length(ref) <= 256) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256)) AND ((char_length(thread_ref) >= 1) AND (char_length(thread_ref) <= 1024)) AND ((char_length(message_ref) >= 1) AND (char_length(message_ref) <= 1024)) AND (card_ui_revision >= 0) AND ((card_fingerprint IS NULL) OR (char_length(card_fingerprint) = 64)) AND ((rendered_publication_offer_ref IS NULL) OR ((char_length(rendered_publication_offer_ref) >= 1) AND (char_length(rendered_publication_offer_ref) <= 256))) AND (attempt_count >= 0) AND (((lease_owner IS NULL) AND (lease_ref IS NULL) AND (lease_expires_at IS NULL)) OR ((char_length(lease_owner) > 0) AND (lease_ref IS NOT NULL) AND (lease_expires_at IS NOT NULL)))))
);

CREATE TABLE public.slack_thread_status_receipts (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    thread_ref text NOT NULL,
    generation bigint NOT NULL,
    lease_ref uuid NOT NULL,
    origin_kind text,
    origin_id uuid,
    phase text NOT NULL,
    text text NOT NULL,
    error text,
    acknowledged_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL
);

CREATE TABLE public.slack_thread_statuses (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    thread_ref text NOT NULL,
    phase text NOT NULL,
    desired_text text NOT NULL,
    generation bigint DEFAULT 1 NOT NULL,
    delivered_generation bigint DEFAULT 0 NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt_count bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp without time zone,
    lease_owner text,
    lease_ref uuid,
    lease_expires_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    delivered_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    origin_kind text,
    origin_id uuid,
    CONSTRAINT slack_thread_status_valid CHECK ((((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256)) AND (thread_ref ~ '^[0-9]{10,}\.[0-9]{1,6}$'::text) AND (phase = ANY (ARRAY['queued'::text, 'admitting'::text, 'admission_retry'::text, 'working'::text, 'delivery'::text, 'waiting_for_input'::text, 'waiting_for_event'::text, 'blocked'::text, 'clear'::text])) AND (octet_length(desired_text) <= 100) AND (generation >= 1) AND ((delivered_generation >= 0) AND (delivered_generation <= generation)) AND (attempt_count >= 0) AND (status = ANY (ARRAY['pending'::text, 'delivered'::text, 'blocked'::text])) AND (((status = ANY (ARRAY['pending'::text, 'blocked'::text])) AND (delivered_generation < generation)) OR ((status = 'delivered'::text) AND (delivered_generation = generation))) AND (((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'pending'::text) AND (lease_ref IS NOT NULL) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL))) AND (((last_error_code IS NULL) AND (last_error_detail IS NULL)) OR ((status = ANY (ARRAY['pending'::text, 'blocked'::text])) AND ((char_length(last_error_code) >= 1) AND (char_length(last_error_code) <= 128)) AND ((octet_length(last_error_detail) >= 1) AND (octet_length(last_error_detail) <= 4096)))) AND ((status <> 'delivered'::text) OR ((delivered_at IS NOT NULL) AND (next_attempt_at IS NULL) AND (lease_ref IS NULL) AND (last_error_code IS NULL))) AND ((status <> 'blocked'::text) OR ((last_error_code IS NOT NULL) AND (next_attempt_at IS NULL) AND (lease_ref IS NULL)))))
);

CREATE TABLE public.standing_assignment_runs (
    id uuid NOT NULL,
    ref text NOT NULL,
    assignment_id uuid NOT NULL,
    source_input_ref text NOT NULL,
    source_event_ref text NOT NULL,
    outcome text NOT NULL,
    decision_action text,
    decision_ref text,
    episode_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT standing_assignment_run_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(source_input_ref) >= 1) AND (char_length(source_input_ref) <= 1024)) AND ((char_length(source_event_ref) >= 1) AND (char_length(source_event_ref) <= 1024)) AND (outcome = ANY (ARRAY['pending'::text, 'decided'::text, 'superseded'::text])) AND (((outcome = 'pending'::text) AND (decision_action IS NULL) AND (decision_ref IS NULL) AND (episode_id IS NULL)) OR ((outcome = ANY (ARRAY['decided'::text, 'superseded'::text])) AND (decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text, 'quick_reply'::text, 'react'::text, 'ignore'::text])) AND ((char_length(decision_ref) >= 1) AND (char_length(decision_ref) <= 1024)) AND (((decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text])) AND (episode_id IS NOT NULL)) OR ((decision_action = ANY (ARRAY['quick_reply'::text, 'react'::text, 'ignore'::text])) AND (episode_id IS NULL)))))))
);

CREATE TABLE public.standing_rule_inventories (
    id uuid NOT NULL,
    source_input_ref text NOT NULL,
    source_event_ref text NOT NULL,
    workspace_ref text NOT NULL,
    conversation_ref text NOT NULL,
    rule_count bigint NOT NULL,
    matched_count bigint NOT NULL,
    truncated boolean DEFAULT false NOT NULL,
    entries text NOT NULL,
    recorded_at timestamp without time zone NOT NULL,
    CONSTRAINT standing_rule_inventory_valid CHECK ((((char_length(source_input_ref) >= 1) AND (char_length(source_input_ref) <= 1024)) AND ((char_length(source_event_ref) >= 1) AND (char_length(source_event_ref) <= 1024)) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 1024)) AND ((char_length(conversation_ref) >= 1) AND (char_length(conversation_ref) <= 1024)) AND (rule_count >= 0) AND (matched_count >= 0) AND (matched_count <= rule_count) AND (octet_length(entries) >= 2) AND (jsonb_typeof((entries)::jsonb) = 'array'::text)))
);

CREATE TABLE public.webhook_source_settings (
    name text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    adapter_kind text NOT NULL,
    auth_kind text NOT NULL,
    secret_name text NOT NULL,
    destination_transport text NOT NULL,
    destination_conversation_ref text NOT NULL,
    destination_thread_ref text,
    environment_ref text CONSTRAINT webhook_source_settings_context_ref_not_null NOT NULL,
    group_by_labels text[] DEFAULT ARRAY[]::text[] NOT NULL,
    mapping jsonb,
    publication_lifecycle jsonb,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT webhook_source_settings_valid CHECK (((name ~ '^[a-z][a-z0-9_-]{0,63}$'::text) AND (adapter_kind = ANY (ARRAY['universal'::text, 'grafana'::text, 'mapped_json'::text])) AND (auth_kind = ANY (ARRAY['bearer'::text, 'hmac_sha256'::text])) AND (secret_name ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'::text) AND (destination_transport ~ '^[a-z][a-z0-9_-]{0,63}$'::text) AND ((char_length(destination_conversation_ref) >= 1) AND (char_length(destination_conversation_ref) <= 1024)) AND ((destination_thread_ref IS NULL) OR ((char_length(destination_thread_ref) >= 1) AND (char_length(destination_thread_ref) <= 1024))) AND (cardinality(group_by_labels) <= 64) AND ((adapter_kind <> 'mapped_json'::text) OR (mapping IS NOT NULL))))
);

CREATE TABLE public.work_candidate_responses (
    turn_id uuid NOT NULL,
    candidate_attempt bigint NOT NULL,
    body text,
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    recorded_at timestamp without time zone NOT NULL,
    operational_pruned_at timestamp without time zone,
    CONSTRAINT work_candidate_response_identity_valid CHECK (((candidate_attempt > 0) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 262144)))),
    CONSTRAINT work_candidate_response_retention_valid CHECK ((((operational_pruned_at IS NULL) AND (body IS NOT NULL) AND (octet_length(body) = byte_size)) OR ((operational_pruned_at IS NOT NULL) AND (body IS NULL))))
);

CREATE TABLE public.work_input_artifact_references (
    turn_id uuid NOT NULL,
    artifact_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.work_output_artifacts (
    id uuid NOT NULL,
    turn_id uuid NOT NULL,
    ref text NOT NULL,
    name text NOT NULL,
    media_type text NOT NULL,
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    data bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT work_output_artifact_identity_valid CHECK (((char_length(ref) >= 1) AND (char_length(ref) <= 256) AND (ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND ((char_length(name) >= 1) AND (char_length(name) <= 255)) AND (media_type = ANY (ARRAY['image/png'::text, 'image/jpeg'::text, 'image/webp'::text, 'image/gif'::text])) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 8388608)) AND (octet_length(data) = byte_size)))
);

CREATE TABLE public.work_settings (
    id text NOT NULL,
    workspace_ref text,
    routing_model text DEFAULT 'codex:gpt-5.6-sol/medium@default'::text NOT NULL,
    conversation_model text DEFAULT 'codex:gpt-5.6-terra/medium@default'::text NOT NULL,
    standard_model text DEFAULT 'codex:gpt-5.6-sol/medium@default'::text NOT NULL,
    deep_model text DEFAULT 'codex:gpt-5.6-sol/xhigh@default'::text NOT NULL,
    contributor_model text DEFAULT 'codex:gpt-5.6-sol/medium@default'::text NOT NULL,
    schedule_model text DEFAULT 'codex:gpt-5.6-sol/medium@default'::text NOT NULL,
    incident_model text DEFAULT 'codex:gpt-5.6-sol/medium@default'::text NOT NULL,
    learning_model text DEFAULT 'codex:gpt-5.6-sol/medium@default'::text NOT NULL,
    CONSTRAINT work_settings_contributor_model_valid CHECK ((contributor_model ~ '^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT work_settings_conversation_model_valid CHECK ((conversation_model ~ '^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT work_settings_deep_model_valid CHECK ((deep_model ~ '^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT work_settings_incident_model_valid CHECK ((incident_model ~ '^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT work_settings_learning_model_valid CHECK ((learning_model ~ '^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT work_settings_routing_model_valid CHECK ((routing_model ~ '^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT work_settings_schedule_model_valid CHECK ((schedule_model ~ '^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT work_settings_standard_model_valid CHECK ((standard_model ~ '^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT work_settings_valid CHECK (((workspace_ref IS NULL) OR ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256))))
);

ALTER TABLE ONLY public.coop_worker_events ALTER COLUMN id SET DEFAULT nextval('public.coop_worker_events_id_seq'::regclass);

ALTER TABLE ONLY public.episode_state_records ALTER COLUMN sequence SET DEFAULT nextval('public.episode_state_records_sequence_seq'::regclass);

ALTER TABLE ONLY public.admission_attempts
    ADD CONSTRAINT admission_attempts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.control_plane_conversations
    ADD CONSTRAINT control_plane_conversations_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.conversation_knowledge
    ADD CONSTRAINT conversation_knowledge_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.conversation_knowledge_revisions
    ADD CONSTRAINT conversation_knowledge_revisions_pkey PRIMARY KEY (knowledge_id, version);

ALTER TABLE ONLY public.conversation_knowledge_sources
    ADD CONSTRAINT conversation_knowledge_sources_pkey PRIMARY KEY (knowledge_id, generation, receipt_fingerprint);

ALTER TABLE ONLY public.conversation_learning_batches
    ADD CONSTRAINT conversation_learning_batches_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.conversation_learning_inputs
    ADD CONSTRAINT conversation_learning_inputs_pkey PRIMARY KEY (input_id);

ALTER TABLE ONLY public.conversation_learning_runs
    ADD CONSTRAINT conversation_learning_runs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.conversation_observations
    ADD CONSTRAINT conversation_observations_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.conversation_rollups
    ADD CONSTRAINT conversation_rollups_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.conversation_summaries
    ADD CONSTRAINT conversation_summaries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.conversation_summary_drafts
    ADD CONSTRAINT conversation_summary_drafts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_session_evidence
    ADD CONSTRAINT coop_session_evidence_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placements_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_worker_certificates
    ADD CONSTRAINT coop_worker_certificates_pkey PRIMARY KEY (sha256);

ALTER TABLE ONLY public.coop_worker_commands
    ADD CONSTRAINT coop_worker_commands_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_worker_enrollment_tokens
    ADD CONSTRAINT coop_worker_enrollment_tokens_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_worker_events
    ADD CONSTRAINT coop_worker_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_worker_output_transfers
    ADD CONSTRAINT coop_worker_output_transfers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_worker_review_patch_transfers
    ADD CONSTRAINT coop_worker_review_patch_transfers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_worker_workspace_checkpoints
    ADD CONSTRAINT coop_worker_workspace_checkpoints_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.coop_workers
    ADD CONSTRAINT coop_workers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.delivery_routing_responses
    ADD CONSTRAINT delivery_routing_responses_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.emisar_connection_settings
    ADD CONSTRAINT emisar_connection_settings_pkey PRIMARY KEY (ref);

ALTER TABLE ONLY public.environment_repository_settings
    ADD CONSTRAINT environment_repository_settings_pkey PRIMARY KEY (environment_ref, repository_ref);

ALTER TABLE ONLY public.environment_settings
    ADD CONSTRAINT environment_settings_pkey PRIMARY KEY (ref);

ALTER TABLE ONLY public.episode_case_records
    ADD CONSTRAINT episode_case_records_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_correlation_claims
    ADD CONSTRAINT episode_correlation_claims_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_emisar_approvals
    ADD CONSTRAINT episode_emisar_approvals_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_event_subscriptions
    ADD CONSTRAINT episode_event_subscriptions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_input_origins
    ADD CONSTRAINT episode_input_origins_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_kernel_episodes
    ADD CONSTRAINT episode_kernel_episodes_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_kernel_events
    ADD CONSTRAINT episode_kernel_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_operator_reviews
    ADD CONSTRAINT episode_operator_reviews_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_publication_followups
    ADD CONSTRAINT episode_publication_followups_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_publication_lifecycle_events
    ADD CONSTRAINT episode_publication_lifecycle_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_publications
    ADD CONSTRAINT episode_publications_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_routing_digests
    ADD CONSTRAINT episode_routing_digests_pkey PRIMARY KEY (episode_id);

ALTER TABLE ONLY public.episode_schedule_occurrences
    ADD CONSTRAINT episode_schedule_occurrences_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_schedules
    ADD CONSTRAINT episode_schedules_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_state_record_responses
    ADD CONSTRAINT episode_state_record_responses_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_state_records
    ADD CONSTRAINT episode_state_records_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_work_activity
    ADD CONSTRAINT episode_work_activity_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_work_knowledge_exposures
    ADD CONSTRAINT episode_work_knowledge_exposures_pkey PRIMARY KEY (session_id, knowledge_id, version);

ALTER TABLE ONLY public.episode_work_sessions
    ADD CONSTRAINT episode_work_sessions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_work_source_exposures
    ADD CONSTRAINT episode_work_source_exposures_pkey PRIMARY KEY (session_id, observation_id, source_input_id);

ALTER TABLE ONLY public.episode_work_state_tool_calls
    ADD CONSTRAINT episode_work_state_tool_calls_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.episode_work_turns
    ADD CONSTRAINT episode_work_turns_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.execution_usage
    ADD CONSTRAINT execution_usage_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.github_binding_settings
    ADD CONSTRAINT github_binding_settings_pkey PRIMARY KEY (name);

ALTER TABLE ONLY public.github_repository_events
    ADD CONSTRAINT github_repository_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.github_settings
    ADD CONSTRAINT github_settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ingress_inbox_entries
    ADD CONSTRAINT ingress_inbox_entries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ingress_input_artifact_references
    ADD CONSTRAINT ingress_input_artifact_references_pkey PRIMARY KEY (input_id, artifact_id);

ALTER TABLE ONLY public.input_artifacts
    ADD CONSTRAINT input_artifacts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.input_custody_transitions
    ADD CONSTRAINT input_custody_transitions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.installation_settings
    ADD CONSTRAINT installation_settings_pkey PRIMARY KEY (host_ref);

ALTER TABLE ONLY public.integration_credential_events
    ADD CONSTRAINT integration_credential_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.integration_credentials
    ADD CONSTRAINT integration_credentials_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.learning_settings
    ADD CONSTRAINT learning_settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.memory_review_items
    ADD CONSTRAINT memory_review_items_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.model_instruction_edits
    ADD CONSTRAINT model_instruction_edits_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.model_instruction_settings
    ADD CONSTRAINT model_instruction_settings_pkey PRIMARY KEY (scope_ref);

ALTER TABLE ONLY public.operational_memory_entries
    ADD CONSTRAINT operational_memory_entries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.operator_behaviors
    ADD CONSTRAINT operator_behaviors_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.platform_actions
    ADD CONSTRAINT platform_actions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.policy_bindings
    ADD CONSTRAINT policy_bindings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.pricing_rates
    ADD CONSTRAINT pricing_rates_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.publication_settings
    ADD CONSTRAINT publication_settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.report_settings
    ADD CONSTRAINT report_settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.repository_settings
    ADD CONSTRAINT repository_settings_pkey PRIMARY KEY (ref);

ALTER TABLE ONLY public.retention_operator_actions
    ADD CONSTRAINT retention_operator_actions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.retention_settings
    ADD CONSTRAINT retention_settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ryker_operator_actions
    ADD CONSTRAINT ryker_operator_actions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ryker_runtime_progress
    ADD CONSTRAINT ryker_runtime_progress_pkey PRIMARY KEY (lane);

ALTER TABLE ONLY public.settings_edits
    ADD CONSTRAINT settings_edits_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.settings_import_receipts
    ADD CONSTRAINT settings_import_receipts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_channel_configurations
    ADD CONSTRAINT slack_channel_configurations_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_channel_membership_events
    ADD CONSTRAINT slack_channel_membership_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_channel_memberships
    ADD CONSTRAINT slack_channel_memberships_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_channel_setting_audit
    ADD CONSTRAINT slack_channel_setting_audit_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_configuration_actions
    ADD CONSTRAINT slack_configuration_actions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_configuration_sessions
    ADD CONSTRAINT slack_configuration_sessions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_incident_room_lifecycle_events
    ADD CONSTRAINT slack_incident_room_lifecycle_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_incident_rooms
    ADD CONSTRAINT slack_incident_rooms_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_interaction_audit
    ADD CONSTRAINT slack_interaction_audit_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_settings
    ADD CONSTRAINT slack_settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_source_audits
    ADD CONSTRAINT slack_source_audits_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_task_cards
    ADD CONSTRAINT slack_task_cards_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_thread_status_receipts
    ADD CONSTRAINT slack_thread_status_receipts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.slack_thread_statuses
    ADD CONSTRAINT slack_thread_statuses_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.standing_assignment_runs
    ADD CONSTRAINT standing_assignment_runs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.standing_rule_inventories
    ADD CONSTRAINT standing_rule_inventories_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.webhook_source_settings
    ADD CONSTRAINT webhook_source_settings_pkey PRIMARY KEY (name);

ALTER TABLE ONLY public.work_candidate_responses
    ADD CONSTRAINT work_candidate_responses_pkey PRIMARY KEY (turn_id, candidate_attempt);

ALTER TABLE ONLY public.work_input_artifact_references
    ADD CONSTRAINT work_input_artifact_references_pkey PRIMARY KEY (turn_id, artifact_id);

ALTER TABLE ONLY public.work_output_artifacts
    ADD CONSTRAINT work_output_artifacts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.work_settings
    ADD CONSTRAINT work_settings_pkey PRIMARY KEY (id);

CREATE UNIQUE INDEX admission_attempts_input_id_generation_index ON public.admission_attempts USING btree (input_id, generation);

CREATE INDEX admission_attempts_inserted_at_id_index ON public.admission_attempts USING btree (inserted_at, id);

CREATE INDEX control_plane_conversations_environment_ref_index ON public.control_plane_conversations USING btree (environment_ref);

CREATE INDEX conversation_knowledge_anchor_keys_index ON public.conversation_knowledge USING gin (anchor_keys);

CREATE UNIQUE INDEX conversation_knowledge_scope_key_topic_key_index ON public.conversation_knowledge USING btree (scope_key, topic_key);

CREATE INDEX conversation_knowledge_search ON public.conversation_knowledge USING gin (to_tsvector('simple'::regconfig, state));

CREATE INDEX conversation_knowledge_sources_knowledge_id_generation_introduc ON public.conversation_knowledge_sources USING btree (knowledge_id, generation, introduced_version);

CREATE INDEX conversation_knowledge_updated_at_index ON public.conversation_knowledge USING btree (updated_at);

CREATE INDEX conversation_knowledge_workspace_ref_conversation_ref_updated_a ON public.conversation_knowledge USING btree (workspace_ref, conversation_ref, updated_at);

CREATE UNIQUE INDEX conversation_learning_applied_once ON public.conversation_learning_runs USING btree (batch_key) WHERE (status = 'applied'::text);

CREATE INDEX conversation_learning_batches_scope_key_inserted_at_index ON public.conversation_learning_batches USING btree (scope_key, inserted_at);

CREATE INDEX conversation_learning_batches_status_next_attempt_at_inserted_a ON public.conversation_learning_batches USING btree (status, next_attempt_at, inserted_at);

CREATE INDEX conversation_learning_inputs_batch_id_input_id_index ON public.conversation_learning_inputs USING btree (batch_id, input_id);

CREATE INDEX conversation_learning_runs_batch_id_generation_index ON public.conversation_learning_runs USING btree (batch_id, generation);

CREATE UNIQUE INDEX conversation_learning_runs_batch_key_generation_index ON public.conversation_learning_runs USING btree (batch_key, generation);

CREATE UNIQUE INDEX conversation_observations_identity_key_index ON public.conversation_observations USING btree (identity_key);

CREATE INDEX conversation_observations_reply_subject ON public.conversation_observations USING btree (conversation_ref, COALESCE(thread_ref, source_message_ref));

CREATE INDEX conversation_observations_scope_time ON public.conversation_observations USING btree (workspace_ref, conversation_ref, occurred_at);

CREATE INDEX conversation_observations_updated_at_index ON public.conversation_observations USING btree (updated_at);

CREATE INDEX conversation_rollups_expires_at_index ON public.conversation_rollups USING btree (expires_at);

CREATE UNIQUE INDEX conversation_rollups_identity ON public.conversation_rollups USING btree (workspace_ref, scope_kind, scope_ref, period_start);

CREATE INDEX conversation_rollups_recall ON public.conversation_rollups USING btree (workspace_ref, scope_kind, scope_ref, period_end);

CREATE UNIQUE INDEX conversation_rollups_ref_index ON public.conversation_rollups USING btree (ref);

CREATE INDEX conversation_summaries_compaction_retry_at_updated_at_index ON public.conversation_summaries USING btree (compaction_retry_at, updated_at);

CREATE UNIQUE INDEX conversation_summaries_identity_key_index ON public.conversation_summaries USING btree (identity_key);

CREATE INDEX conversation_summaries_recall ON public.conversation_summaries USING btree (workspace_ref, visibility, updated_at);

CREATE UNIQUE INDEX conversation_summaries_ref_index ON public.conversation_summaries USING btree (ref);

CREATE INDEX conversation_summaries_repository_ref_updated_at_index ON public.conversation_summaries USING btree (repository_ref, updated_at);

CREATE UNIQUE INDEX conversation_summary_drafts_turn_id_index ON public.conversation_summary_drafts USING btree (turn_id);

CREATE INDEX coop_session_evidence_episode_id_index ON public.coop_session_evidence USING btree (episode_id);

CREATE INDEX coop_session_evidence_first_captured_at_index ON public.coop_session_evidence USING btree (first_captured_at);

CREATE UNIQUE INDEX coop_session_evidence_session_id_content_fingerprint_index ON public.coop_session_evidence USING btree (session_id, content_fingerprint);

CREATE INDEX coop_session_evidence_session_id_last_captured_at_index ON public.coop_session_evidence USING btree (session_id, last_captured_at);

CREATE UNIQUE INDEX coop_session_placements_command_identity ON public.coop_session_placements USING btree (id, worker_id, session_id, generation);

CREATE UNIQUE INDEX coop_session_placements_one_current ON public.coop_session_placements USING btree (session_id) WHERE (state = ANY (ARRAY['assigning'::text, 'active'::text, 'draining'::text, 'revoking'::text]));

CREATE UNIQUE INDEX coop_session_placements_session_id_generation_index ON public.coop_session_placements USING btree (session_id, generation);

CREATE INDEX coop_session_placements_worker_id_state_lease_expires_at_index ON public.coop_session_placements USING btree (worker_id, state, lease_expires_at);

CREATE INDEX coop_worker_certificates_worker_id_expires_at_index ON public.coop_worker_certificates USING btree (worker_id, expires_at);

CREATE UNIQUE INDEX coop_worker_commands_id_worker_id_index ON public.coop_worker_commands USING btree (id, worker_id);

CREATE UNIQUE INDEX coop_worker_commands_idempotency_key_index ON public.coop_worker_commands USING btree (idempotency_key);

CREATE INDEX coop_worker_commands_placement_id_inserted_at_index ON public.coop_worker_commands USING btree (placement_id, inserted_at);

CREATE INDEX coop_worker_commands_worker_id_status_inserted_at_id_index ON public.coop_worker_commands USING btree (worker_id, status, inserted_at, id);

CREATE UNIQUE INDEX coop_worker_enrollment_tokens_token_sha256_index ON public.coop_worker_enrollment_tokens USING btree (token_sha256);

CREATE INDEX coop_worker_enrollment_tokens_worker_id_expires_at_index ON public.coop_worker_enrollment_tokens USING btree (worker_id, expires_at);

CREATE UNIQUE INDEX coop_worker_events_placement_id_sequence_index ON public.coop_worker_events USING btree (placement_id, ((kind = 'session_event'::text)), sequence);

CREATE INDEX coop_worker_events_session_id_placement_generation_sequence_ind ON public.coop_worker_events USING btree (session_id, placement_generation, sequence);

CREATE UNIQUE INDEX coop_worker_output_transfers_command_id_artifact_ref_index ON public.coop_worker_output_transfers USING btree (command_id, artifact_ref);

CREATE UNIQUE INDEX coop_worker_review_patch_transfers_command_id_artifact_id_index ON public.coop_worker_review_patch_transfers USING btree (command_id, artifact_id);

CREATE UNIQUE INDEX coop_worker_workspace_checkpoints_command_ref_index ON public.coop_worker_workspace_checkpoints USING btree (command_id, checkpoint_ref);

CREATE INDEX coop_worker_workspace_checkpoints_session_ref_placement_generat ON public.coop_worker_workspace_checkpoints USING btree (session_ref, placement_generation);

CREATE UNIQUE INDEX coop_workers_certificate_sha256_index ON public.coop_workers USING btree (certificate_sha256);

CREATE INDEX coop_workers_workspace_ref_state_last_seen_at_index ON public.coop_workers USING btree (workspace_ref, state, last_seen_at);

CREATE INDEX delivery_routing_responses_claimable ON public.delivery_routing_responses USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);

CREATE UNIQUE INDEX delivery_routing_responses_delivery_ref_index ON public.delivery_routing_responses USING btree (delivery_ref);

CREATE UNIQUE INDEX delivery_routing_responses_input_id_index ON public.delivery_routing_responses USING btree (input_id);

CREATE UNIQUE INDEX emisar_connection_endpoint_account_index ON public.emisar_connection_settings USING btree (rpc_url, account_ref);

CREATE UNIQUE INDEX environment_repository_settings_position_index ON public.environment_repository_settings USING btree (environment_ref, "position");

CREATE INDEX environment_repository_settings_repository_ref_index ON public.environment_repository_settings USING btree (repository_ref);

CREATE UNIQUE INDEX environment_settings_default_index ON public.environment_settings USING btree (is_default) WHERE is_default;

CREATE INDEX environment_settings_emisar_connection_ref_index ON public.environment_settings USING btree (emisar_connection_ref);

CREATE INDEX episode_case_record_search ON public.episode_case_records USING gin (to_tsvector('english'::regconfig, search_text));

CREATE INDEX episode_case_records_anchor_keys_index ON public.episode_case_records USING gin (anchor_keys);

CREATE UNIQUE INDEX episode_case_records_case_ref_index ON public.episode_case_records USING btree (case_ref);

CREATE INDEX episode_case_records_conversation_ref_index ON public.episode_case_records USING btree (conversation_ref);

CREATE INDEX episode_case_records_workspace_ref_status_index ON public.episode_case_records USING btree (workspace_ref, status);

CREATE UNIQUE INDEX episode_correlation_claim_owner ON public.episode_correlation_claims USING btree (scope_ref, namespace, occurrence_ref) WHERE (status = 'active'::text);

CREATE INDEX episode_correlation_claims_episode_id_index ON public.episode_correlation_claims USING btree (episode_id);

CREATE INDEX episode_emisar_approvals_claimable ON public.episode_emisar_approvals USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);

CREATE UNIQUE INDEX episode_emisar_approvals_connection_ref_request_id_index ON public.episode_emisar_approvals USING btree (connection_ref, request_id);

CREATE INDEX episode_emisar_approvals_connection_ref_status_next_attempt_at_ ON public.episode_emisar_approvals USING btree (connection_ref, status, next_attempt_at);

CREATE INDEX episode_emisar_approvals_episode_id_status_index ON public.episode_emisar_approvals USING btree (episode_id, status);

CREATE UNIQUE INDEX episode_emisar_approvals_record_id_index ON public.episode_emisar_approvals USING btree (record_id);

CREATE INDEX episode_event_subscriptions_list_order ON public.episode_event_subscriptions USING btree (status, updated_at DESC, id DESC);

CREATE UNIQUE INDEX episode_event_subscriptions_one_active_episode_index ON public.episode_event_subscriptions USING btree (episode_id) WHERE (status = 'active'::text);

CREATE UNIQUE INDEX episode_event_subscriptions_record_id_index ON public.episode_event_subscriptions USING btree (record_id);

CREATE UNIQUE INDEX episode_event_subscriptions_ref_index ON public.episode_event_subscriptions USING btree (ref);

CREATE INDEX episode_event_subscriptions_status_deadline_at_index ON public.episode_event_subscriptions USING btree (status, deadline_at);

CREATE INDEX episode_event_subscriptions_status_poll_after_index ON public.episode_event_subscriptions USING btree (status, poll_after);

CREATE INDEX episode_input_origin_thread_chronology ON public.episode_input_origins USING btree (transport, conversation_ref, thread_ref, occurred_at);

CREATE UNIQUE INDEX episode_input_origins_episode_id_input_ref_index ON public.episode_input_origins USING btree (episode_id, input_ref);

CREATE INDEX episode_input_origins_episode_id_sequence_index ON public.episode_input_origins USING btree (episode_id, sequence);

CREATE INDEX episode_input_origins_native_input_id_index ON public.episode_input_origins USING btree (native_input_id);

CREATE INDEX episode_kernel_episode_destination ON public.episode_kernel_episodes USING btree (destination_transport, destination_conversation_ref, destination_thread_ref);

CREATE UNIQUE INDEX episode_kernel_episodes_key_index ON public.episode_kernel_episodes USING btree (key);

CREATE INDEX episode_kernel_episodes_linked_episode_id_index ON public.episode_kernel_episodes USING btree (linked_episode_id);

CREATE INDEX episode_kernel_event_input_endpoints ON public.episode_kernel_events USING btree (episode_id, kind, occurred_at, dedupe_key);

CREATE UNIQUE INDEX episode_kernel_events_episode_id_dedupe_key_index ON public.episode_kernel_events USING btree (episode_id, dedupe_key);

CREATE UNIQUE INDEX episode_kernel_events_episode_id_sequence_index ON public.episode_kernel_events USING btree (episode_id, sequence);

CREATE INDEX episode_kernel_history_retention ON public.episode_kernel_episodes USING btree (history_pruned_at, updated_at, id);

CREATE INDEX episode_kernel_input_chronology ON public.episode_kernel_events USING btree (episode_id, kind, occurred_at, sequence);

CREATE UNIQUE INDEX episode_operator_reviews_episode_id_semantic_version_index ON public.episode_operator_reviews USING btree (episode_id, semantic_version);

CREATE INDEX episode_operator_reviews_reviewed_at_index ON public.episode_operator_reviews USING btree (reviewed_at);

CREATE INDEX episode_publication_followups_due ON public.episode_publication_followups USING btree (next_poll_at, lease_expires_at, inserted_at, id);

CREATE UNIQUE INDEX episode_publication_followups_publication_id_index ON public.episode_publication_followups USING btree (publication_id);

CREATE INDEX episode_publication_lifecycle_delivery_due ON public.episode_publication_lifecycle_events USING btree (delivery_state, next_attempt_at, lease_expires_at, inserted_at, id);

CREATE UNIQUE INDEX episode_publication_lifecycle_events_delivery_ref_index ON public.episode_publication_lifecycle_events USING btree (delivery_ref);

CREATE INDEX episode_publication_lifecycle_events_publication_id_occurred_at ON public.episode_publication_lifecycle_events USING btree (publication_id, occurred_at, id);

CREATE UNIQUE INDEX episode_publication_lifecycle_events_ref_index ON public.episode_publication_lifecycle_events USING btree (ref);

CREATE UNIQUE INDEX episode_publications_approval_ref_index ON public.episode_publications USING btree (approval_ref) WHERE (approval_ref IS NOT NULL);

CREATE INDEX episode_publications_claimable ON public.episode_publications USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);

CREATE INDEX episode_publications_episode_id_inserted_at_index ON public.episode_publications USING btree (episode_id, inserted_at);

CREATE UNIQUE INDEX episode_publications_id_episode_id_index ON public.episode_publications USING btree (id, episode_id);

CREATE UNIQUE INDEX episode_publications_record_id_index ON public.episode_publications USING btree (record_id);

CREATE UNIQUE INDEX episode_publications_ref_index ON public.episode_publications USING btree (ref);

CREATE UNIQUE INDEX episode_publications_review_request_ref_index ON public.episode_publications USING btree (review_request_ref);

CREATE INDEX episode_routing_digest_search_vector ON public.episode_routing_digests USING gin (search_vector);

CREATE INDEX episode_routing_digests_anchor_keys_index ON public.episode_routing_digests USING gin (anchor_keys);

CREATE UNIQUE INDEX episode_schedule_occurrences_child_episode_id_index ON public.episode_schedule_occurrences USING btree (child_episode_id) WHERE (child_episode_id IS NOT NULL);

CREATE UNIQUE INDEX episode_schedule_occurrences_ref_index ON public.episode_schedule_occurrences USING btree (ref);

CREATE INDEX episode_schedule_occurrences_schedule_id_scheduled_for_id_index ON public.episode_schedule_occurrences USING btree (schedule_id, scheduled_for, id);

CREATE UNIQUE INDEX episode_schedule_occurrences_schedule_id_scheduled_for_index ON public.episode_schedule_occurrences USING btree (schedule_id, scheduled_for);

CREATE INDEX episode_schedules_destination_transport_destination_conversatio ON public.episode_schedules USING btree (destination_transport, destination_conversation_ref);

CREATE INDEX episode_schedules_due ON public.episode_schedules USING btree (status, next_occurrence_at, next_attempt_at, lease_expires_at, id);

CREATE UNIQUE INDEX episode_schedules_offer_record_id_index ON public.episode_schedules USING btree (offer_record_id);

CREATE UNIQUE INDEX episode_schedules_ref_index ON public.episode_schedules USING btree (ref);

CREATE UNIQUE INDEX episode_state_record_goal_subject_index ON public.episode_state_records USING btree (episode_id, subject_ref) WHERE (kind = 'goal'::text);

CREATE UNIQUE INDEX episode_state_record_responses_inbox_entry_id_index ON public.episode_state_record_responses USING btree (inbox_entry_id);

CREATE UNIQUE INDEX episode_state_record_responses_record_id_index ON public.episode_state_record_responses USING btree (record_id);

CREATE UNIQUE INDEX episode_state_record_responses_response_ref_index ON public.episode_state_record_responses USING btree (response_ref);

CREATE INDEX episode_state_record_subject_timeline_index ON public.episode_state_records USING btree (episode_id, kind, subject_ref, inserted_at);

CREATE UNIQUE INDEX episode_state_records_confirmed_episode_id_index ON public.episode_state_records USING btree (confirmed_episode_id) WHERE (confirmed_episode_id IS NOT NULL);

CREATE INDEX episode_state_records_episode_id_inserted_at_index ON public.episode_state_records USING btree (episode_id, inserted_at);

CREATE INDEX episode_state_records_episode_id_sequence_index ON public.episode_state_records USING btree (episode_id, sequence);

CREATE UNIQUE INDEX episode_state_records_ref_index ON public.episode_state_records USING btree (ref);

CREATE UNIQUE INDEX episode_state_records_sequence_index ON public.episode_state_records USING btree (sequence);

CREATE UNIQUE INDEX episode_state_records_turn_id_operation_id_index ON public.episode_state_records USING btree (turn_id, operation_id);

CREATE INDEX episode_work_activity_admission_input_id_occurred_at_sequence_i ON public.episode_work_activity USING btree (admission_input_id, occurred_at, sequence);

CREATE INDEX episode_work_activity_coop_turn_id_sequence_index ON public.episode_work_activity USING btree (coop_turn_id, sequence);

CREATE INDEX episode_work_activity_episode_id_occurred_at_sequence_index ON public.episode_work_activity USING btree (episode_id, occurred_at, sequence);

CREATE UNIQUE INDEX episode_work_activity_remote_event_id_index ON public.episode_work_activity USING btree (remote_event_id);

CREATE UNIQUE INDEX episode_work_activity_session_id_remote_session_id_sequence_ind ON public.episode_work_activity USING btree (session_id, remote_session_id, sequence);

CREATE UNIQUE INDEX episode_work_sessions_admission_external_ref_index ON public.episode_work_sessions USING btree (external_ref) WHERE (execution_kind = 'admission'::text);

CREATE INDEX episode_work_sessions_cleanup_claimable ON public.episode_work_sessions USING btree (cleanup_status, cleanup_next_attempt_at, cleanup_lease_expires_at, inserted_at, id);

CREATE UNIQUE INDEX episode_work_sessions_coop_session_id_index ON public.episode_work_sessions USING btree (coop_session_id) WHERE (coop_session_id IS NOT NULL);

CREATE UNIQUE INDEX episode_work_sessions_episode_id_generation_index ON public.episode_work_sessions USING btree (episode_id, generation);

CREATE UNIQUE INDEX episode_work_sessions_id_admission_input_id_index ON public.episode_work_sessions USING btree (id, admission_input_id);

CREATE UNIQUE INDEX episode_work_sessions_id_episode_id_index ON public.episode_work_sessions USING btree (id, episode_id);

CREATE UNIQUE INDEX episode_work_sessions_id_learning_run_id_index ON public.episode_work_sessions USING btree (id, learning_run_id);

CREATE UNIQUE INDEX episode_work_sessions_learning_run_id_index ON public.episode_work_sessions USING btree (learning_run_id) WHERE (execution_kind = 'learning'::text);

CREATE INDEX episode_work_state_tool_calls_turn_id_called_at_index ON public.episode_work_state_tool_calls USING btree (turn_id, called_at);

CREATE INDEX episode_work_turn_operational_retention ON public.episode_work_turns USING btree (operational_pruned_at, updated_at, id);

CREATE INDEX episode_work_turns_accepted_at_execution_target_index ON public.episode_work_turns USING btree (accepted_at, execution_target);

CREATE INDEX episode_work_turns_claimable ON public.episode_work_turns USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);

CREATE UNIQUE INDEX episode_work_turns_coop_turn_id_index ON public.episode_work_turns USING btree (coop_turn_id) WHERE (coop_turn_id IS NOT NULL);

CREATE UNIQUE INDEX episode_work_turns_delivery_ref_index ON public.episode_work_turns USING btree (delivery_ref) WHERE (delivery_ref IS NOT NULL);

CREATE INDEX episode_work_turns_episode_id_inserted_at_index ON public.episode_work_turns USING btree (episode_id, inserted_at);

CREATE UNIQUE INDEX episode_work_turns_episode_id_turn_ref_index ON public.episode_work_turns USING btree (episode_id, turn_ref);

CREATE UNIQUE INDEX episode_work_turns_id_episode_id_index ON public.episode_work_turns USING btree (id, episode_id);

CREATE UNIQUE INDEX episode_work_turns_result_ref_index ON public.episode_work_turns USING btree (result_ref) WHERE (result_ref IS NOT NULL);

CREATE INDEX episode_work_turns_session_id_index ON public.episode_work_turns USING btree (session_id);

CREATE INDEX execution_usage_episode_id_recorded_at_index ON public.execution_usage USING btree (episode_id, recorded_at);

CREATE UNIQUE INDEX execution_usage_kind_source_id_generation_index ON public.execution_usage USING btree (kind, source_id, generation);

CREATE INDEX execution_usage_recorded_at_id_index ON public.execution_usage USING btree (recorded_at, id);

CREATE UNIQUE INDEX github_binding_settings_repository_ref_index ON public.github_binding_settings USING btree (repository_ref);

CREATE UNIQUE INDEX github_repository_events_binding_ref_delivery_ref_index ON public.github_repository_events USING btree (binding_ref, delivery_ref);

CREATE INDEX github_repository_events_binding_ref_occurred_at_index ON public.github_repository_events USING btree (binding_ref, occurred_at);

CREATE INDEX guidance_search_page ON public.operator_behaviors USING btree (workspace_ref, scope_kind, scope_ref, COALESCE(edited_at, confirmed_at) DESC, id DESC) WHERE ((status = 'active'::text) AND (kind = 'guidance'::text));

CREATE INDEX ingress_inbox_claimable ON public.ingress_inbox_entries USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);

CREATE UNIQUE INDEX ingress_inbox_entries_decision_ref_index ON public.ingress_inbox_entries USING btree (decision_ref) WHERE (decision_ref IS NOT NULL);

CREATE UNIQUE INDEX ingress_inbox_entries_dedupe_key_index ON public.ingress_inbox_entries USING btree (dedupe_key);

CREATE INDEX ingress_inbox_entries_episode_id_occurred_at_index ON public.ingress_inbox_entries USING btree (episode_id, occurred_at);

CREATE INDEX ingress_inbox_entries_source_kind_source_ref_occurred_at_index ON public.ingress_inbox_entries USING btree (source_kind, source_ref, occurred_at);

CREATE INDEX ingress_inbox_operational_retention ON public.ingress_inbox_entries USING btree (operational_pruned_at, updated_at, id);

CREATE INDEX ingress_inbox_source_revisions ON public.ingress_inbox_entries USING btree (source_kind, source_ref, native_input_id, revision);

CREATE INDEX ingress_input_artifact_references_artifact_id_index ON public.ingress_input_artifact_references USING btree (artifact_id);

CREATE INDEX ingress_pending_conversation_order ON public.ingress_inbox_entries USING btree (destination_transport, destination_conversation_ref, execution_mode, inserted_at, id) WHERE (status = 'pending'::text);

CREATE UNIQUE INDEX input_artifacts_ref_index ON public.input_artifacts USING btree (ref);

CREATE UNIQUE INDEX input_artifacts_source_kind_source_ref_index ON public.input_artifacts USING btree (source_kind, source_ref);

CREATE INDEX input_custody_transitions_input_id_occurred_at_sequence_index ON public.input_custody_transitions USING btree (input_id, occurred_at, sequence);

CREATE UNIQUE INDEX input_custody_transitions_input_id_sequence_index ON public.input_custody_transitions USING btree (input_id, sequence);

CREATE UNIQUE INDEX installation_settings_singleton_index ON public.installation_settings USING btree (singleton);

CREATE INDEX integration_credential_events_kind_name_inserted_at_index ON public.integration_credential_events USING btree (kind, name, inserted_at);

CREATE UNIQUE INDEX integration_credentials_kind_name_index ON public.integration_credentials USING btree (kind, name);

CREATE INDEX knowledge_sources_observation_lookup ON public.conversation_knowledge_sources USING btree (observation_id, knowledge_id, generation);

CREATE UNIQUE INDEX learning_one_active_scope ON public.conversation_learning_batches USING btree (scope_key) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));

CREATE UNIQUE INDEX learning_one_rebuild_generation ON public.conversation_learning_batches USING btree (rebuild_target_id, rebuild_target_generation) WHERE (rebuild_target_id IS NOT NULL);

CREATE INDEX learning_pending_input_order ON public.ingress_inbox_entries USING btree (inserted_at, id) WHERE (status = ANY (ARRAY['decided'::text, 'superseded'::text]));

CREATE UNIQUE INDEX learning_session_external_identity ON public.episode_work_sessions USING btree (external_ref) WHERE (execution_kind = 'learning'::text);

CREATE UNIQUE INDEX memory_review_items_ref_index ON public.memory_review_items USING btree (ref);

CREATE UNIQUE INDEX memory_review_items_source_digest_index ON public.memory_review_items USING btree (source_digest);

CREATE INDEX memory_review_items_workspace_ref_status_inserted_at_index ON public.memory_review_items USING btree (workspace_ref, status, inserted_at);

CREATE UNIQUE INDEX model_instruction_edits_scope_ref_revision_index ON public.model_instruction_edits USING btree (scope_ref, revision);

CREATE UNIQUE INDEX operational_memory_active_identity ON public.operational_memory_entries USING btree (workspace_ref, scope_kind, scope_ref, kind, subject) WHERE (status = 'active'::text);

CREATE UNIQUE INDEX operational_memory_answer_confirmation ON public.operational_memory_entries USING btree (confirmation_ref) WHERE (answer_provenance IS NOT NULL);

CREATE INDEX operational_memory_context ON public.operational_memory_entries USING btree (workspace_ref, status, visibility, expires_at, updated_at);

CREATE UNIQUE INDEX operational_memory_entries_offer_record_id_index ON public.operational_memory_entries USING btree (offer_record_id);

CREATE UNIQUE INDEX operational_memory_entries_ref_index ON public.operational_memory_entries USING btree (ref);

CREATE INDEX operational_memory_search_page ON public.operational_memory_entries USING btree (workspace_ref, scope_kind, scope_ref, COALESCE(edited_at, confirmed_at) DESC, id DESC) WHERE (status = 'active'::text);

CREATE UNIQUE INDEX operator_behaviors_active_identity ON public.operator_behaviors USING btree (kind, workspace_ref, scope_kind, scope_ref, identity_key) WHERE (status = 'active'::text);

CREATE INDEX operator_behaviors_context ON public.operator_behaviors USING btree (workspace_ref, kind, status, expires_at, updated_at);

CREATE UNIQUE INDEX operator_behaviors_offer_record_id_index ON public.operator_behaviors USING btree (offer_record_id);

CREATE UNIQUE INDEX operator_behaviors_ref_index ON public.operator_behaviors USING btree (ref);

CREATE UNIQUE INDEX platform_actions_action_ref_index ON public.platform_actions USING btree (action_ref);

CREATE INDEX platform_actions_claimable ON public.platform_actions USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);

CREATE UNIQUE INDEX platform_actions_turn_id_host_slot_index ON public.platform_actions USING btree (turn_id, host_slot);

CREATE UNIQUE INDEX policy_bindings_purpose_scope_kind_scope_ref_repository_ref_ind ON public.policy_bindings USING btree (purpose, scope_kind, scope_ref, repository_ref);

CREATE UNIQUE INDEX pricing_rates_execution_target_effective_from_index ON public.pricing_rates USING btree (execution_target, effective_from);

CREATE INDEX repository_settings_materialization_due_index ON public.repository_settings USING btree (github_access, last_github_event_at, materialized_at);

CREATE UNIQUE INDEX retention_operator_actions_action_ref_index ON public.retention_operator_actions USING btree (action_ref);

CREATE INDEX retention_operator_actions_session_id_occurred_at_id_index ON public.retention_operator_actions USING btree (session_id, occurred_at, id);

CREATE UNIQUE INDEX ryker_operator_actions_action_ref_index ON public.ryker_operator_actions USING btree (action_ref);

CREATE INDEX ryker_operator_actions_occurred_at_id_index ON public.ryker_operator_actions USING btree (occurred_at, id);

CREATE UNIQUE INDEX settings_edits_revision_index ON public.settings_edits USING btree (revision);

CREATE UNIQUE INDEX settings_import_receipts_source_fingerprint_index ON public.settings_import_receipts USING btree (source_fingerprint);

CREATE UNIQUE INDEX slack_channel_configurations_workspace_ref_channel_ref_index ON public.slack_channel_configurations USING btree (workspace_ref, channel_ref);

CREATE UNIQUE INDEX slack_channel_membership_events_workspace_ref_event_ref_index ON public.slack_channel_membership_events USING btree (workspace_ref, event_ref);

CREATE UNIQUE INDEX slack_channel_memberships_workspace_ref_channel_ref_index ON public.slack_channel_memberships USING btree (workspace_ref, channel_ref);

CREATE UNIQUE INDEX slack_channel_setting_audit_event_ref_index ON public.slack_channel_setting_audit USING btree (event_ref);

CREATE INDEX slack_channel_setting_audit_workspace_ref_occurred_at_id_index ON public.slack_channel_setting_audit USING btree (workspace_ref, occurred_at, id);

CREATE UNIQUE INDEX slack_configuration_actions_event_ref_index ON public.slack_configuration_actions USING btree (event_ref);

CREATE UNIQUE INDEX slack_configuration_sessions_active_channel_index ON public.slack_configuration_sessions USING btree (workspace_ref, channel_ref) WHERE (status = ANY (ARRAY['asking'::text, 'confirming'::text]));

CREATE UNIQUE INDEX slack_configuration_sessions_start_event_ref_index ON public.slack_configuration_sessions USING btree (start_event_ref);

CREATE INDEX slack_configuration_sessions_status_expires_at_index ON public.slack_configuration_sessions USING btree (status, expires_at);

CREATE INDEX slack_incident_room_lifecycle_events_room_id_occurred_at_event_ ON public.slack_incident_room_lifecycle_events USING btree (room_id, occurred_at, event_ref);

CREATE UNIQUE INDEX slack_incident_room_lifecycle_events_workspace_ref_event_ref_in ON public.slack_incident_room_lifecycle_events USING btree (workspace_ref, event_ref);

CREATE UNIQUE INDEX slack_incident_rooms_episode_id_index ON public.slack_incident_rooms USING btree (episode_id) WHERE (episode_id IS NOT NULL);

CREATE UNIQUE INDEX slack_incident_rooms_record_id_index ON public.slack_incident_rooms USING btree (record_id);

CREATE UNIQUE INDEX slack_incident_rooms_ref_index ON public.slack_incident_rooms USING btree (ref);

CREATE INDEX slack_incident_rooms_status_next_attempt_at_inserted_at_index ON public.slack_incident_rooms USING btree (status, next_attempt_at, inserted_at) WHERE (status = 'requested'::text);

CREATE INDEX slack_incident_rooms_status_next_attempt_at_updated_at_index ON public.slack_incident_rooms USING btree (status, next_attempt_at, updated_at) WHERE ((status = 'ready'::text) AND (channel_state <> reconciled_channel_state));

CREATE INDEX slack_incident_rooms_status_root_card_checked_at_updated_at_ind ON public.slack_incident_rooms USING btree (status, root_card_checked_at, updated_at) WHERE ((status = 'ready'::text) AND (channel_state = 'active'::text));

CREATE UNIQUE INDEX slack_incident_rooms_workspace_ref_channel_name_index ON public.slack_incident_rooms USING btree (workspace_ref, channel_name);

CREATE UNIQUE INDEX slack_incident_rooms_workspace_ref_channel_ref_index ON public.slack_incident_rooms USING btree (workspace_ref, channel_ref) WHERE (channel_ref IS NOT NULL);

CREATE UNIQUE INDEX slack_interaction_audit_event_ref_index ON public.slack_interaction_audit USING btree (event_ref);

CREATE INDEX slack_interaction_audit_workspace_ref_occurred_at_id_index ON public.slack_interaction_audit USING btree (workspace_ref, occurred_at, id);

CREATE INDEX slack_interaction_repaint_due ON public.slack_interaction_audit USING btree (repaint_status, next_attempt_at, occurred_at, id);

CREATE INDEX slack_source_audits_episode_id_inserted_at_id_index ON public.slack_source_audits USING btree (episode_id, inserted_at, id);

CREATE INDEX slack_source_audits_turn_id_inserted_at_id_index ON public.slack_source_audits USING btree (turn_id, inserted_at, id);

CREATE INDEX slack_task_cards_due ON public.slack_task_cards USING btree (card_checked_at, updated_at);

CREATE UNIQUE INDEX slack_task_cards_episode_id_index ON public.slack_task_cards USING btree (episode_id);

CREATE UNIQUE INDEX slack_task_cards_record_id_index ON public.slack_task_cards USING btree (record_id);

CREATE UNIQUE INDEX slack_task_cards_ref_index ON public.slack_task_cards USING btree (ref);

CREATE INDEX slack_thread_status_due_index ON public.slack_thread_statuses USING btree (workspace_ref, status, next_attempt_at, updated_at);

CREATE UNIQUE INDEX slack_thread_status_identity_unique ON public.slack_thread_statuses USING btree (workspace_ref, channel_ref, thread_ref);

CREATE UNIQUE INDEX slack_thread_status_receipts_lease_ref_index ON public.slack_thread_status_receipts USING btree (lease_ref);

CREATE INDEX slack_thread_status_receipts_origin_kind_origin_id_inserted_at_ ON public.slack_thread_status_receipts USING btree (origin_kind, origin_id, inserted_at);

CREATE INDEX slack_thread_status_receipts_workspace_ref_channel_ref_thread_r ON public.slack_thread_status_receipts USING btree (workspace_ref, channel_ref, thread_ref, inserted_at);

CREATE UNIQUE INDEX standing_assignment_runs_assignment_id_source_input_ref_index ON public.standing_assignment_runs USING btree (assignment_id, source_input_ref);

CREATE UNIQUE INDEX standing_assignment_runs_ref_index ON public.standing_assignment_runs USING btree (ref);

CREATE INDEX standing_rule_inventories_recorded_at_index ON public.standing_rule_inventories USING btree (recorded_at);

CREATE UNIQUE INDEX standing_rule_inventories_source_input_ref_index ON public.standing_rule_inventories USING btree (source_input_ref);

CREATE INDEX work_input_artifact_references_artifact_id_index ON public.work_input_artifact_references USING btree (artifact_id);

CREATE UNIQUE INDEX work_output_artifacts_turn_id_ref_index ON public.work_output_artifacts USING btree (turn_id, ref);

CREATE UNIQUE INDEX work_output_artifacts_turn_id_sha256_index ON public.work_output_artifacts USING btree (turn_id, sha256);

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.admission_attempts FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.control_plane_conversations FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_knowledge FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_knowledge_revisions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_knowledge_sources FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_learning_batches FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_learning_inputs FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_learning_runs FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_observations FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_rollups FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_summaries FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.conversation_summary_drafts FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_session_evidence FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_session_placements FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_worker_certificates FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_worker_commands FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_worker_enrollment_tokens FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_worker_events FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_worker_output_transfers FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_worker_review_patch_transfers FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_worker_workspace_checkpoints FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.coop_workers FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.delivery_routing_responses FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.environment_repository_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.environment_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_case_records FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_correlation_claims FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_emisar_approvals FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_event_subscriptions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_input_origins FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_kernel_episodes FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_kernel_events FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_operator_reviews FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_publication_followups FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_publication_lifecycle_events FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_publications FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_routing_digests FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_schedule_occurrences FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_schedules FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_state_record_responses FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_state_records FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_work_activity FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_work_knowledge_exposures FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_work_sessions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_work_source_exposures FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_work_state_tool_calls FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.episode_work_turns FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.execution_usage FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.github_binding_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.github_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.ingress_inbox_entries FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.ingress_input_artifact_references FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.input_artifacts FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.input_custody_transitions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.installation_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.learning_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.memory_review_items FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.model_instruction_edits FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.model_instruction_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.operational_memory_entries FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.operator_behaviors FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.platform_actions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.policy_bindings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.pricing_rates FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.publication_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.report_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.repository_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.retention_operator_actions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.retention_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.ryker_operator_actions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.settings_edits FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.settings_import_receipts FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_channel_configurations FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_channel_membership_events FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_channel_memberships FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_channel_setting_audit FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_configuration_actions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_configuration_sessions FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_incident_room_lifecycle_events FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_incident_rooms FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_interaction_audit FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_source_audits FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_task_cards FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_thread_status_receipts FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.slack_thread_statuses FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.standing_assignment_runs FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.standing_rule_inventories FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.webhook_source_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.work_candidate_responses FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.work_input_artifact_references FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.work_output_artifacts FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON public.work_settings FOR EACH STATEMENT EXECUTE FUNCTION public.ryker_control_plane_notify();

ALTER TABLE ONLY public.episode_work_activity
    ADD CONSTRAINT activity_admission_session_fkey FOREIGN KEY (session_id, admission_input_id) REFERENCES public.episode_work_sessions(id, admission_input_id);

ALTER TABLE ONLY public.admission_attempts
    ADD CONSTRAINT admission_attempts_input_id_fkey FOREIGN KEY (input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.control_plane_conversations
    ADD CONSTRAINT control_plane_conversations_environment_ref_fkey FOREIGN KEY (environment_ref) REFERENCES public.environment_settings(ref) ON DELETE SET NULL;

ALTER TABLE ONLY public.conversation_knowledge_revisions
    ADD CONSTRAINT conversation_knowledge_revisions_knowledge_id_fkey FOREIGN KEY (knowledge_id) REFERENCES public.conversation_knowledge(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.conversation_knowledge_sources
    ADD CONSTRAINT conversation_knowledge_sources_knowledge_id_fkey FOREIGN KEY (knowledge_id) REFERENCES public.conversation_knowledge(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.conversation_learning_batches
    ADD CONSTRAINT conversation_learning_batches_rebuild_target_id_fkey FOREIGN KEY (rebuild_target_id) REFERENCES public.conversation_knowledge(id);

ALTER TABLE ONLY public.conversation_learning_inputs
    ADD CONSTRAINT conversation_learning_inputs_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.conversation_learning_batches(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.conversation_learning_inputs
    ADD CONSTRAINT conversation_learning_inputs_input_id_fkey FOREIGN KEY (input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.conversation_learning_runs
    ADD CONSTRAINT conversation_learning_runs_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.conversation_learning_batches(id);

ALTER TABLE ONLY public.conversation_summaries
    ADD CONSTRAINT conversation_summaries_source_episode_id_fkey FOREIGN KEY (source_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.conversation_summary_drafts
    ADD CONSTRAINT conversation_summary_draft_turn_episode_fkey FOREIGN KEY (turn_id, episode_id) REFERENCES public.episode_work_turns(id, episode_id) ON DELETE CASCADE;

ALTER TABLE ONLY public.conversation_summary_drafts
    ADD CONSTRAINT conversation_summary_drafts_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.conversation_summaries
    ADD CONSTRAINT conversation_summary_source_turn_episode_fkey FOREIGN KEY (source_turn_id, source_episode_id) REFERENCES public.episode_work_turns(id, episode_id) ON DELETE SET NULL;

ALTER TABLE ONLY public.coop_session_evidence
    ADD CONSTRAINT coop_session_evidence_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.coop_session_evidence
    ADD CONSTRAINT coop_session_evidence_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.episode_work_sessions(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placement_session_episode_fkey FOREIGN KEY (session_id, episode_id) REFERENCES public.episode_work_sessions(id, episode_id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placements_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placements_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.episode_work_sessions(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placements_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.coop_workers(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.coop_worker_certificates
    ADD CONSTRAINT coop_worker_certificates_enrollment_token_id_fkey FOREIGN KEY (enrollment_token_id) REFERENCES public.coop_worker_enrollment_tokens(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.coop_worker_certificates
    ADD CONSTRAINT coop_worker_certificates_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.coop_workers(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.coop_worker_commands
    ADD CONSTRAINT coop_worker_command_placement_identity_fkey FOREIGN KEY (placement_id, worker_id, session_id, placement_generation) REFERENCES public.coop_session_placements(id, worker_id, session_id, generation) ON DELETE RESTRICT;

ALTER TABLE ONLY public.coop_worker_events
    ADD CONSTRAINT coop_worker_event_placement_identity_fkey FOREIGN KEY (placement_id, worker_id, session_id, placement_generation) REFERENCES public.coop_session_placements(id, worker_id, session_id, generation) ON DELETE RESTRICT;

ALTER TABLE ONLY public.coop_worker_output_transfers
    ADD CONSTRAINT coop_worker_output_transfer_command_worker_fkey FOREIGN KEY (command_id, worker_id) REFERENCES public.coop_worker_commands(id, worker_id) ON DELETE CASCADE;

ALTER TABLE ONLY public.coop_worker_review_patch_transfers
    ADD CONSTRAINT coop_worker_review_patch_command_worker_fkey FOREIGN KEY (command_id, worker_id) REFERENCES public.coop_worker_commands(id, worker_id) ON DELETE CASCADE;

ALTER TABLE ONLY public.coop_worker_workspace_checkpoints
    ADD CONSTRAINT coop_worker_workspace_checkpoint_command_worker_fkey FOREIGN KEY (command_id, worker_id) REFERENCES public.coop_worker_commands(id, worker_id) ON DELETE CASCADE;

ALTER TABLE ONLY public.delivery_routing_responses
    ADD CONSTRAINT delivery_routing_responses_input_id_fkey FOREIGN KEY (input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.environment_repository_settings
    ADD CONSTRAINT environment_repository_settings_environment_ref_fkey FOREIGN KEY (environment_ref) REFERENCES public.environment_settings(ref) ON DELETE CASCADE;

ALTER TABLE ONLY public.environment_repository_settings
    ADD CONSTRAINT environment_repository_settings_repository_ref_fkey FOREIGN KEY (repository_ref) REFERENCES public.repository_settings(ref) ON DELETE RESTRICT;

ALTER TABLE ONLY public.environment_settings
    ADD CONSTRAINT environment_settings_emisar_connection_ref_fkey FOREIGN KEY (emisar_connection_ref) REFERENCES public.emisar_connection_settings(ref) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_correlation_claims
    ADD CONSTRAINT episode_correlation_claims_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_emisar_approvals
    ADD CONSTRAINT episode_emisar_approvals_connection_ref_fkey FOREIGN KEY (connection_ref) REFERENCES public.emisar_connection_settings(ref) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_emisar_approvals
    ADD CONSTRAINT episode_emisar_approvals_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_emisar_approvals
    ADD CONSTRAINT episode_emisar_approvals_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_event_subscriptions
    ADD CONSTRAINT episode_event_subscriptions_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_event_subscriptions
    ADD CONSTRAINT episode_event_subscriptions_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_input_origins
    ADD CONSTRAINT episode_input_origins_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_kernel_episodes
    ADD CONSTRAINT episode_kernel_episodes_linked_episode_id_fkey FOREIGN KEY (linked_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_kernel_events
    ADD CONSTRAINT episode_kernel_events_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_operator_reviews
    ADD CONSTRAINT episode_operator_reviews_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_publication_followups
    ADD CONSTRAINT episode_publication_followup_publication_episode_fkey FOREIGN KEY (publication_id, episode_id) REFERENCES public.episode_publications(id, episode_id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_publication_followups
    ADD CONSTRAINT episode_publication_followups_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_publication_lifecycle_events
    ADD CONSTRAINT episode_publication_lifecycle_events_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_publication_lifecycle_events
    ADD CONSTRAINT episode_publication_lifecycle_publication_episode_fkey FOREIGN KEY (publication_id, episode_id) REFERENCES public.episode_publications(id, episode_id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_publications
    ADD CONSTRAINT episode_publication_session_episode_fkey FOREIGN KEY (session_id, episode_id) REFERENCES public.episode_work_sessions(id, episode_id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_publications
    ADD CONSTRAINT episode_publications_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_publications
    ADD CONSTRAINT episode_publications_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_routing_digests
    ADD CONSTRAINT episode_routing_digests_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_schedule_occurrences
    ADD CONSTRAINT episode_schedule_occurrences_child_episode_id_fkey FOREIGN KEY (child_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_schedule_occurrences
    ADD CONSTRAINT episode_schedule_occurrences_schedule_id_fkey FOREIGN KEY (schedule_id) REFERENCES public.episode_schedules(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_schedules
    ADD CONSTRAINT episode_schedules_offer_record_id_fkey FOREIGN KEY (offer_record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_schedules
    ADD CONSTRAINT episode_schedules_source_episode_id_fkey FOREIGN KEY (source_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_state_record_responses
    ADD CONSTRAINT episode_state_record_responses_inbox_entry_id_fkey FOREIGN KEY (inbox_entry_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_state_record_responses
    ADD CONSTRAINT episode_state_record_responses_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_state_records
    ADD CONSTRAINT episode_state_record_turn_episode_fkey FOREIGN KEY (turn_id, episode_id) REFERENCES public.episode_work_turns(id, episode_id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_state_records
    ADD CONSTRAINT episode_state_records_confirmed_episode_id_fkey FOREIGN KEY (confirmed_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_state_records
    ADD CONSTRAINT episode_state_records_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_work_activity
    ADD CONSTRAINT episode_work_activity_admission_input_id_fkey FOREIGN KEY (admission_input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_work_activity
    ADD CONSTRAINT episode_work_activity_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_work_activity
    ADD CONSTRAINT episode_work_activity_session_episode_fkey FOREIGN KEY (session_id, episode_id) REFERENCES public.episode_work_sessions(id, episode_id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_work_knowledge_exposures
    ADD CONSTRAINT episode_work_knowledge_exposures_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.episode_work_sessions(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_work_sessions
    ADD CONSTRAINT episode_work_sessions_admission_input_id_fkey FOREIGN KEY (admission_input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.episode_work_sessions
    ADD CONSTRAINT episode_work_sessions_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_work_sessions
    ADD CONSTRAINT episode_work_sessions_learning_run_id_fkey FOREIGN KEY (learning_run_id) REFERENCES public.conversation_learning_runs(id);

ALTER TABLE ONLY public.episode_work_source_exposures
    ADD CONSTRAINT episode_work_source_exposures_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.episode_work_sessions(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_work_state_tool_calls
    ADD CONSTRAINT episode_work_state_tool_calls_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.episode_work_turns
    ADD CONSTRAINT episode_work_turn_session_episode_fkey FOREIGN KEY (session_id, episode_id) REFERENCES public.episode_work_sessions(id, episode_id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.episode_work_turns
    ADD CONSTRAINT episode_work_turns_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.github_binding_settings
    ADD CONSTRAINT github_binding_settings_repository_ref_fkey FOREIGN KEY (repository_ref) REFERENCES public.repository_settings(ref);

ALTER TABLE ONLY public.github_settings
    ADD CONSTRAINT github_settings_id_fkey FOREIGN KEY (id) REFERENCES public.installation_settings(host_ref) ON DELETE CASCADE;

ALTER TABLE ONLY public.ingress_inbox_entries
    ADD CONSTRAINT ingress_inbox_entries_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.ingress_input_artifact_references
    ADD CONSTRAINT ingress_input_artifact_references_artifact_id_fkey FOREIGN KEY (artifact_id) REFERENCES public.input_artifacts(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.ingress_input_artifact_references
    ADD CONSTRAINT ingress_input_artifact_references_input_id_fkey FOREIGN KEY (input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.input_custody_transitions
    ADD CONSTRAINT input_custody_transitions_input_id_fkey FOREIGN KEY (input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.input_custody_transitions
    ADD CONSTRAINT input_custody_transitions_predecessor_input_id_fkey FOREIGN KEY (predecessor_input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.input_custody_transitions
    ADD CONSTRAINT input_custody_transitions_superseding_input_id_fkey FOREIGN KEY (superseding_input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.integration_credential_events
    ADD CONSTRAINT integration_credential_events_credential_id_fkey FOREIGN KEY (credential_id) REFERENCES public.integration_credentials(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.learning_settings
    ADD CONSTRAINT learning_settings_id_fkey FOREIGN KEY (id) REFERENCES public.installation_settings(host_ref) ON DELETE CASCADE;

ALTER TABLE ONLY public.model_instruction_edits
    ADD CONSTRAINT model_instruction_edits_scope_ref_fkey FOREIGN KEY (scope_ref) REFERENCES public.model_instruction_settings(scope_ref);

ALTER TABLE ONLY public.operational_memory_entries
    ADD CONSTRAINT operational_memory_entries_offer_record_id_fkey FOREIGN KEY (offer_record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.operator_behaviors
    ADD CONSTRAINT operator_behaviors_offer_record_id_fkey FOREIGN KEY (offer_record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.platform_actions
    ADD CONSTRAINT platform_actions_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.platform_actions
    ADD CONSTRAINT platform_actions_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.publication_settings
    ADD CONSTRAINT publication_settings_id_fkey FOREIGN KEY (id) REFERENCES public.installation_settings(host_ref) ON DELETE CASCADE;

ALTER TABLE ONLY public.report_settings
    ADD CONSTRAINT report_settings_id_fkey FOREIGN KEY (id) REFERENCES public.installation_settings(host_ref) ON DELETE CASCADE;

ALTER TABLE ONLY public.retention_operator_actions
    ADD CONSTRAINT retention_operator_actions_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.episode_work_sessions(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.retention_settings
    ADD CONSTRAINT retention_settings_id_fkey FOREIGN KEY (id) REFERENCES public.installation_settings(host_ref) ON DELETE CASCADE;

ALTER TABLE ONLY public.slack_channel_configurations
    ADD CONSTRAINT slack_channel_configurations_environment_ref_fkey FOREIGN KEY (environment_ref) REFERENCES public.environment_settings(ref) ON DELETE SET NULL;

ALTER TABLE ONLY public.slack_channel_membership_events
    ADD CONSTRAINT slack_channel_membership_events_membership_id_fkey FOREIGN KEY (membership_id) REFERENCES public.slack_channel_memberships(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.slack_configuration_actions
    ADD CONSTRAINT slack_configuration_actions_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.slack_configuration_sessions(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.slack_incident_room_lifecycle_events
    ADD CONSTRAINT slack_incident_room_lifecycle_events_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.slack_incident_rooms(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.slack_incident_rooms
    ADD CONSTRAINT slack_incident_rooms_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.slack_incident_rooms
    ADD CONSTRAINT slack_incident_rooms_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.slack_incident_rooms
    ADD CONSTRAINT slack_incident_rooms_source_episode_id_fkey FOREIGN KEY (source_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.slack_settings
    ADD CONSTRAINT slack_settings_id_fkey FOREIGN KEY (id) REFERENCES public.installation_settings(host_ref) ON DELETE CASCADE;

ALTER TABLE ONLY public.slack_source_audits
    ADD CONSTRAINT slack_source_audits_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.slack_source_audits
    ADD CONSTRAINT slack_source_audits_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.slack_task_cards
    ADD CONSTRAINT slack_task_cards_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.slack_task_cards
    ADD CONSTRAINT slack_task_cards_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.standing_assignment_runs
    ADD CONSTRAINT standing_assignment_runs_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.operator_behaviors(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.standing_assignment_runs
    ADD CONSTRAINT standing_assignment_runs_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.webhook_source_settings
    ADD CONSTRAINT webhook_source_settings_environment_ref_fkey FOREIGN KEY (environment_ref) REFERENCES public.environment_settings(ref) ON DELETE RESTRICT;

ALTER TABLE ONLY public.work_candidate_responses
    ADD CONSTRAINT work_candidate_responses_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.work_input_artifact_references
    ADD CONSTRAINT work_input_artifact_references_artifact_id_fkey FOREIGN KEY (artifact_id) REFERENCES public.input_artifacts(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.work_input_artifact_references
    ADD CONSTRAINT work_input_artifact_references_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.work_output_artifacts
    ADD CONSTRAINT work_output_artifacts_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.work_settings
    ADD CONSTRAINT work_settings_id_fkey FOREIGN KEY (id) REFERENCES public.installation_settings(host_ref) ON DELETE CASCADE;

INSERT INTO public.pricing_rates
  (id, execution_target, input_usd_per_million, cached_input_usd_per_million,
   output_usd_per_million, reasoning_usd_per_million, effective_from, revision,
   provenance, inserted_at)
VALUES
  ('965d6213-adc4-40b3-8972-e654169ec25c', 'codex:gpt-5.6-sol', 4, 0.40, 20, NULL, '2026-09-05', 1, 'https://developers.openai.com/api/docs/pricing', NOW()),
  ('b974d5b1-eab3-4e53-a466-781f92fe9558', 'codex:gpt-5.6-terra', 2, 0.20, 12, NULL, '2026-09-05', 1, 'https://developers.openai.com/api/docs/pricing', NOW()),
  ('d47b779d-1768-4df7-9910-08666322d285', 'codex:gpt-5.6-luna', 0.20, 0.02, 1.20, NULL, '2026-09-05', 1, 'https://developers.openai.com/api/docs/pricing', NOW());
