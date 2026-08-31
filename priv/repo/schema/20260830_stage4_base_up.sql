ALTER TABLE public.episode_kernel_episodes
  ADD COLUMN execution_mode text DEFAULT 'live' NOT NULL,
  ADD COLUMN history_pruned_at timestamp without time zone;

ALTER TABLE public.episode_kernel_episodes
  ADD CONSTRAINT episode_kernel_execution_mode_valid
  CHECK (execution_mode IN ('live', 'shadow'));

ALTER TABLE public.episode_work_sessions
  ALTER COLUMN episode_id DROP NOT NULL,
  ADD COLUMN execution_kind text DEFAULT 'work' NOT NULL,
  ADD COLUMN repository_ref text,
  ADD COLUMN cleanup_status text DEFAULT 'active' NOT NULL,
  ADD COLUMN cleanup_attempt_count bigint DEFAULT 0 NOT NULL,
  ADD COLUMN cleanup_lease_ref text,
  ADD COLUMN cleanup_lease_owner text,
  ADD COLUMN cleanup_lease_expires_at timestamp without time zone,
  ADD COLUMN cleanup_next_attempt_at timestamp without time zone,
  ADD COLUMN cleanup_last_error_code text,
  ADD COLUMN cleanup_last_error_detail text,
  ADD COLUMN close_generation bigint DEFAULT 1 NOT NULL,
  ADD COLUMN close_expected_revision bigint,
  ADD COLUMN closed_at timestamp without time zone,
  ADD COLUMN discard_after timestamp without time zone,
  ADD COLUMN discard_plan_generation bigint DEFAULT 1 NOT NULL,
  ADD COLUMN discard_plan_expected_revision bigint,
  ADD COLUMN discard_plan_accept_unmerged boolean DEFAULT false NOT NULL,
  ADD COLUMN discard_plan_operation_id text,
  ADD COLUMN discard_plan text,
  ADD COLUMN discard_plan_fingerprint text,
  ADD COLUMN discard_generation bigint DEFAULT 1 NOT NULL,
  ADD COLUMN cleanup_receipt text,
  ADD COLUMN cleanup_receipt_fingerprint text,
  ADD COLUMN retained_reason text,
  ADD COLUMN discarded_at timestamp without time zone,
  ADD COLUMN cleanup_blocked_from text,
  ADD COLUMN workspace_task text;

ALTER TABLE public.episode_work_sessions
  ADD CONSTRAINT episode_work_session_owner_valid
    CHECK (
      (execution_kind = 'work' AND episode_id IS NOT NULL)
      OR (
        execution_kind = 'admission'
        AND episode_id IS NULL
        AND repository_ref IS NULL
        AND workspace_task IS NULL
      )
    ),
  ADD CONSTRAINT episode_work_session_repository_valid
    CHECK (repository_ref IS NULL OR char_length(repository_ref) > 0),
  ADD CONSTRAINT episode_work_session_cleanup_state_valid
    CHECK (
      cleanup_status IN (
        'active', 'close_pending', 'grace', 'plan_pending', 'discard_pending',
        'retained', 'discarded', 'blocked'
      )
      AND cleanup_attempt_count >= 0
      AND close_generation > 0
      AND discard_plan_generation > 0
      AND discard_generation > 0
      AND (close_expected_revision IS NULL OR close_expected_revision > 0)
      AND (discard_plan_expected_revision IS NULL OR discard_plan_expected_revision > 0)
    ),
  ADD CONSTRAINT episode_work_session_cleanup_lease_valid
    CHECK (
      (
        cleanup_lease_ref IS NULL
        AND cleanup_lease_owner IS NULL
        AND cleanup_lease_expires_at IS NULL
      )
      OR (
        char_length(cleanup_lease_ref) BETWEEN 1 AND 1024
        AND char_length(cleanup_lease_owner) BETWEEN 1 AND 1024
        AND cleanup_lease_expires_at IS NOT NULL
        AND cleanup_status IN ('close_pending', 'plan_pending', 'discard_pending')
      )
    ),
  ADD CONSTRAINT episode_work_session_discard_plan_valid
    CHECK (
      (
        discard_plan_operation_id IS NULL
        AND discard_plan IS NULL
        AND discard_plan_fingerprint IS NULL
      )
      OR (
        char_length(discard_plan_operation_id) BETWEEN 1 AND 1024
        AND discard_plan IS NOT NULL
        AND char_length(discard_plan_fingerprint) = 64
      )
    ),
  ADD CONSTRAINT episode_work_session_cleanup_receipt_valid
    CHECK (
      (cleanup_receipt IS NULL AND cleanup_receipt_fingerprint IS NULL)
      OR (cleanup_receipt IS NOT NULL AND char_length(cleanup_receipt_fingerprint) = 64)
    ),
  ADD CONSTRAINT episode_work_session_cleanup_blocked_valid
    CHECK (
      (
        cleanup_status = 'blocked'
        AND (
          cleanup_blocked_from IS NULL
          OR cleanup_blocked_from IN ('close_pending', 'plan_pending', 'discard_pending')
        )
      )
      OR (cleanup_status <> 'blocked' AND cleanup_blocked_from IS NULL)
    ),
  ADD CONSTRAINT episode_work_session_workspace_task_valid
    CHECK (workspace_task IS NULL OR octet_length(workspace_task) <= 65536);

ALTER TABLE public.episode_work_turns
  ADD COLUMN delivery_retry_generation bigint DEFAULT 0 NOT NULL,
  ADD COLUMN operational_pruned_at timestamp without time zone,
  ADD COLUMN state_tools_endpoint text,
  ADD COLUMN state_tools_token_sha256 text,
  ADD COLUMN final_preflight_candidate_sha256 text,
  ADD COLUMN final_preflight_ledger_sha256 text,
  ADD COLUMN final_preflight_semantic_version bigint,
  ADD COLUMN execution_target text,
  ADD COLUMN usage_recorded boolean DEFAULT false NOT NULL,
  ADD COLUMN usage_input_tokens bigint,
  ADD COLUMN usage_cached_input_tokens bigint,
  ADD COLUMN usage_output_tokens bigint,
  ADD COLUMN usage_reasoning_tokens bigint,
  ADD COLUMN usage_cost_usd numeric(24,12),
  ADD COLUMN usage_cost_recorded boolean,
  ADD COLUMN timing_recorded boolean DEFAULT false NOT NULL,
  ADD COLUMN remote_queued_at timestamp without time zone,
  ADD COLUMN remote_started_at timestamp without time zone,
  ADD COLUMN remote_finished_at timestamp without time zone,
  ADD COLUMN usage_queued_ms bigint,
  ADD COLUMN usage_provider_ms bigint,
  ADD COLUMN usage_host_ms bigint,
  ADD COLUMN measurement_error_code text;

ALTER TABLE public.episode_work_turns
  ADD CONSTRAINT episode_work_turns_delivery_retry_generation_check
    CHECK (delivery_retry_generation >= 0),
  ADD CONSTRAINT episode_work_turn_state_tools_binding_valid
    CHECK (
      (state_tools_endpoint IS NULL AND state_tools_token_sha256 IS NULL)
      OR (
        state_tools_endpoint IS NOT NULL
        AND octet_length(state_tools_endpoint) BETWEEN 1 AND 2048
        AND state_tools_token_sha256 IS NOT NULL
        AND char_length(state_tools_token_sha256) = 64
      )
    ),
  ADD CONSTRAINT episode_work_turn_final_preflight_valid
    CHECK (
      (
        final_preflight_candidate_sha256 IS NULL
        AND final_preflight_ledger_sha256 IS NULL
        AND final_preflight_semantic_version IS NULL
      )
      OR (
        final_preflight_candidate_sha256 ~ '^[0-9a-f]{64}$'
        AND final_preflight_ledger_sha256 ~ '^[0-9a-f]{64}$'
        AND final_preflight_semantic_version >= 0
      )
    ),
  ADD CONSTRAINT episode_work_turn_execution_target_valid
    CHECK (execution_target IS NULL OR octet_length(execution_target) BETWEEN 1 AND 512),
  ADD CONSTRAINT episode_work_turn_usage_valid
    CHECK (
      (
        usage_recorded = false
        AND usage_input_tokens IS NULL
        AND usage_cached_input_tokens IS NULL
        AND usage_output_tokens IS NULL
        AND usage_reasoning_tokens IS NULL
        AND usage_cost_usd IS NULL
        AND usage_cost_recorded IS NULL
      )
      OR (
        usage_recorded = true
        AND usage_input_tokens >= 0
        AND usage_cached_input_tokens >= 0
        AND usage_output_tokens >= 0
        AND usage_reasoning_tokens >= 0
        AND usage_cost_usd >= 0
        AND usage_cost_recorded IS NOT NULL
      )
    ),
  ADD CONSTRAINT episode_work_turn_timing_valid
    CHECK (
      (
        timing_recorded = false
        AND remote_queued_at IS NULL
        AND remote_started_at IS NULL
        AND remote_finished_at IS NULL
        AND usage_queued_ms IS NULL
        AND usage_provider_ms IS NULL
        AND usage_host_ms IS NULL
      )
      OR (
        timing_recorded = true
        AND remote_queued_at IS NOT NULL
        AND remote_started_at IS NOT NULL
        AND remote_finished_at IS NOT NULL
        AND remote_queued_at <= remote_started_at
        AND remote_started_at <= remote_finished_at
        AND usage_queued_ms >= 0
        AND usage_provider_ms >= 0
        AND usage_host_ms >= 0
      )
    ),
  ADD CONSTRAINT episode_work_turn_measurement_error_valid
    CHECK (measurement_error_code IS NULL OR octet_length(measurement_error_code) BETWEEN 1 AND 256);

ALTER TABLE public.ingress_inbox_entries ADD COLUMN source_capabilities text;

UPDATE public.ingress_inbox_entries
SET source_capabilities = CASE
  WHEN can_react THEN '{"react":{"emoji_names":null}}'
  ELSE '{}'
END;

ALTER TABLE public.ingress_inbox_entries
  DROP CONSTRAINT ingress_inbox_event_shape_valid,
  DROP CONSTRAINT ingress_inbox_reaction_target_valid,
  DROP COLUMN can_react,
  ALTER COLUMN source_capabilities SET NOT NULL,
  ADD COLUMN execution_mode text DEFAULT 'live' NOT NULL,
  ADD COLUMN work_policy text,
  ADD COLUMN work_policy_digest text,
  ADD COLUMN repository_ref text,
  ADD COLUMN operational_pruned_at timestamp without time zone;

ALTER TABLE public.ingress_inbox_entries
  ADD CONSTRAINT ingress_inbox_event_shape_valid
    CHECK (
      source_kind ~ '^[a-z][a-z0-9_-]{0,63}$'
      AND event_kind IN ('message', 'edit', 'delete', 'event')
      AND actor_kind IN ('user', 'app', 'bot', 'system')
    ),
  ADD CONSTRAINT ingress_inbox_source_capabilities_valid
    CHECK (
      jsonb_typeof(source_capabilities::jsonb) = 'object'
      AND (
        NOT (source_capabilities::jsonb ? 'react')
        OR (source_item_ref IS NOT NULL AND char_length(source_item_ref) > 0)
      )
      AND (
        NOT (source_capabilities::jsonb ? 'post_slack_message')
        OR (
          source_kind = 'slack'
          AND actor_kind = 'user'
          AND source_item_ref IS NOT NULL
          AND char_length(source_item_ref) > 0
          AND jsonb_typeof(source_capabilities::jsonb -> 'post_slack_message') = 'object'
          AND jsonb_typeof(source_capabilities::jsonb -> 'post_slack_message' -> 'destination_refs') = 'array'
          AND jsonb_array_length(source_capabilities::jsonb -> 'post_slack_message' -> 'destination_refs') BETWEEN 1 AND 8
        )
      )
    ),
  ADD CONSTRAINT ingress_inbox_execution_mode_valid
    CHECK (execution_mode IN ('live', 'shadow')),
  ADD CONSTRAINT ingress_inbox_work_profile_valid
    CHECK (
      (work_policy IS NULL AND work_policy_digest IS NULL AND repository_ref IS NULL)
      OR (
        work_policy IS NOT NULL
        AND char_length(work_policy) > 0
        AND work_policy_digest ~ '^[0-9a-f]{64}$'
        AND (repository_ref IS NULL OR char_length(repository_ref) > 0)
      )
    );

CREATE UNIQUE INDEX episode_work_sessions_admission_external_ref_index
  ON public.episode_work_sessions (external_ref)
  WHERE execution_kind = 'admission';

CREATE INDEX episode_kernel_history_retention
  ON public.episode_kernel_episodes (history_pruned_at, updated_at, id);
CREATE INDEX episode_work_sessions_cleanup_claimable
  ON public.episode_work_sessions
  (cleanup_status, cleanup_next_attempt_at, cleanup_lease_expires_at, inserted_at, id);
CREATE INDEX episode_work_turn_operational_retention
  ON public.episode_work_turns (operational_pruned_at, updated_at, id);
CREATE INDEX episode_work_turns_accepted_at_execution_target_index
  ON public.episode_work_turns (accepted_at, execution_target);
CREATE UNIQUE INDEX episode_work_turns_id_episode_id_index
  ON public.episode_work_turns (id, episode_id);
CREATE INDEX ingress_inbox_operational_retention
  ON public.ingress_inbox_entries (operational_pruned_at, updated_at, id);
CREATE INDEX ingress_inbox_source_revisions
  ON public.ingress_inbox_entries (source_kind, source_ref, native_input_id, revision);
