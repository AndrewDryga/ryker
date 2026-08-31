DROP INDEX IF EXISTS public.ingress_inbox_source_revisions;
DROP INDEX IF EXISTS public.ingress_inbox_operational_retention;
DROP INDEX IF EXISTS public.episode_work_turns_id_episode_id_index;
DROP INDEX IF EXISTS public.episode_work_turns_accepted_at_execution_target_index;
DROP INDEX IF EXISTS public.episode_work_turn_operational_retention;
DROP INDEX IF EXISTS public.episode_work_sessions_cleanup_claimable;
DROP INDEX IF EXISTS public.episode_kernel_history_retention;

SELECT 1 / CASE
  WHEN EXISTS (
    SELECT 1 FROM public.ingress_inbox_entries
    WHERE source_kind NOT IN ('slack', 'webhook')
  ) THEN 0
  ELSE 1
END;

ALTER TABLE public.ingress_inbox_entries ADD COLUMN can_react boolean;

UPDATE public.ingress_inbox_entries
SET can_react = source_capabilities::jsonb ? 'react';

ALTER TABLE public.ingress_inbox_entries
  DROP CONSTRAINT ingress_inbox_event_shape_valid,
  DROP CONSTRAINT ingress_inbox_source_capabilities_valid,
  DROP CONSTRAINT ingress_inbox_execution_mode_valid,
  DROP CONSTRAINT ingress_inbox_work_profile_valid,
  ALTER COLUMN can_react SET NOT NULL,
  DROP COLUMN source_capabilities,
  DROP COLUMN execution_mode,
  DROP COLUMN work_policy,
  DROP COLUMN work_policy_digest,
  DROP COLUMN repository_ref,
  DROP COLUMN operational_pruned_at;

ALTER TABLE public.ingress_inbox_entries
  ADD CONSTRAINT ingress_inbox_event_shape_valid
    CHECK (
      source_kind IN ('slack', 'webhook')
      AND event_kind IN ('message', 'edit', 'delete', 'event')
      AND actor_kind IN ('user', 'app', 'bot', 'system')
    ),
  ADD CONSTRAINT ingress_inbox_reaction_target_valid
    CHECK (
      NOT can_react
      OR (source_item_ref IS NOT NULL AND char_length(source_item_ref) > 0)
    );

ALTER TABLE public.episode_work_turns
  DROP CONSTRAINT episode_work_turns_delivery_retry_generation_check,
  DROP CONSTRAINT episode_work_turn_state_tools_binding_valid,
  DROP CONSTRAINT episode_work_turn_final_preflight_valid,
  DROP CONSTRAINT episode_work_turn_execution_target_valid,
  DROP CONSTRAINT episode_work_turn_usage_valid,
  DROP CONSTRAINT episode_work_turn_timing_valid,
  DROP CONSTRAINT episode_work_turn_measurement_error_valid,
  DROP COLUMN delivery_retry_generation,
  DROP COLUMN operational_pruned_at,
  DROP COLUMN state_tools_endpoint,
  DROP COLUMN state_tools_token_sha256,
  DROP COLUMN final_preflight_candidate_sha256,
  DROP COLUMN final_preflight_ledger_sha256,
  DROP COLUMN final_preflight_semantic_version,
  DROP COLUMN execution_target,
  DROP COLUMN usage_recorded,
  DROP COLUMN usage_input_tokens,
  DROP COLUMN usage_cached_input_tokens,
  DROP COLUMN usage_output_tokens,
  DROP COLUMN usage_reasoning_tokens,
  DROP COLUMN usage_cost_usd,
  DROP COLUMN usage_cost_recorded,
  DROP COLUMN timing_recorded,
  DROP COLUMN remote_queued_at,
  DROP COLUMN remote_started_at,
  DROP COLUMN remote_finished_at,
  DROP COLUMN usage_queued_ms,
  DROP COLUMN usage_provider_ms,
  DROP COLUMN usage_host_ms,
  DROP COLUMN measurement_error_code;

DELETE FROM public.episode_work_sessions
WHERE execution_kind = 'admission';

DROP INDEX IF EXISTS public.episode_work_sessions_admission_external_ref_index;

ALTER TABLE public.episode_work_sessions
  DROP CONSTRAINT episode_work_session_owner_valid,
  DROP CONSTRAINT episode_work_session_repository_valid,
  DROP CONSTRAINT episode_work_session_cleanup_state_valid,
  DROP CONSTRAINT episode_work_session_cleanup_lease_valid,
  DROP CONSTRAINT episode_work_session_discard_plan_valid,
  DROP CONSTRAINT episode_work_session_cleanup_receipt_valid,
  DROP CONSTRAINT episode_work_session_cleanup_blocked_valid,
  DROP CONSTRAINT episode_work_session_workspace_task_valid,
  DROP COLUMN repository_ref,
  DROP COLUMN cleanup_status,
  DROP COLUMN cleanup_attempt_count,
  DROP COLUMN cleanup_lease_ref,
  DROP COLUMN cleanup_lease_owner,
  DROP COLUMN cleanup_lease_expires_at,
  DROP COLUMN cleanup_next_attempt_at,
  DROP COLUMN cleanup_last_error_code,
  DROP COLUMN cleanup_last_error_detail,
  DROP COLUMN close_generation,
  DROP COLUMN close_expected_revision,
  DROP COLUMN closed_at,
  DROP COLUMN discard_after,
  DROP COLUMN discard_plan_generation,
  DROP COLUMN discard_plan_expected_revision,
  DROP COLUMN discard_plan_accept_unmerged,
  DROP COLUMN discard_plan_operation_id,
  DROP COLUMN discard_plan,
  DROP COLUMN discard_plan_fingerprint,
  DROP COLUMN discard_generation,
  DROP COLUMN cleanup_receipt,
  DROP COLUMN cleanup_receipt_fingerprint,
  DROP COLUMN retained_reason,
  DROP COLUMN discarded_at,
  DROP COLUMN cleanup_blocked_from,
  DROP COLUMN workspace_task,
  DROP COLUMN execution_kind;

ALTER TABLE public.episode_work_sessions
  ALTER COLUMN episode_id SET NOT NULL;

ALTER TABLE public.episode_kernel_episodes
  DROP CONSTRAINT episode_kernel_execution_mode_valid,
  DROP COLUMN execution_mode,
  DROP COLUMN history_pruned_at;
