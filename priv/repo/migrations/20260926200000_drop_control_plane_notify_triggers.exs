defmodule Ryker.Repo.Migrations.DropControlPlaneNotifyTriggers do
  use Ecto.Migration

  # Open pages used to hear about changes from a statement trigger on 93
  # tables: `ryker_control_plane_notify()` sent the table's name on the
  # `ryker_control_plane` channel and `Ryker.ControlPlane.Updates` mapped it to
  # the pages that might show it. Each context now announces its own changes
  # after they commit (`Ryker.PubSub`), so nothing listens on that channel any
  # more and the triggers only cost every write a NOTIFY. They go; no row
  # changes.
  #
  # Rolling back puts them back on every one of those tables that still
  # exists, for a release that listens again.

  @tables ~w(
    admission_attempts control_plane_conversations conversation_knowledge
    conversation_knowledge_revisions conversation_knowledge_sources
    conversation_learning_batches conversation_learning_inputs conversation_learning_runs
    conversation_observations conversation_rollups conversation_summaries
    conversation_summary_drafts coop_session_evidence coop_session_placements
    coop_worker_certificates coop_worker_commands coop_worker_enrollment_tokens
    coop_worker_events coop_worker_output_transfers coop_worker_review_patch_transfers
    coop_worker_workspace_checkpoints coop_workers delivery_routing_responses
    environment_repository_settings environment_settings episode_case_records
    episode_correlation_claims episode_emisar_approvals episode_event_subscriptions
    episode_input_origins episode_kernel_episodes episode_kernel_events
    episode_operator_reviews episode_publication_followups
    episode_publication_lifecycle_events episode_publications episode_routing_digests
    episode_schedule_occurrences episode_schedules episode_state_record_responses
    episode_state_records episode_work_activity episode_work_knowledge_exposures
    episode_work_sessions episode_work_source_exposures episode_work_state_tool_calls
    episode_work_turns execution_usage github_binding_settings github_settings
    ingress_inbox_entries ingress_input_artifact_references input_artifacts
    input_custody_transitions installation_settings learning_settings memory_review_items
    model_instruction_edits model_instruction_settings operational_memory_entries
    operator_behaviors platform_actions policy_bindings pricing_rates publication_settings
    report_settings repository_settings retention_operator_actions retention_settings
    ryker_operator_actions settings_edits settings_import_receipts
    slack_channel_configurations slack_channel_membership_events slack_channel_memberships
    slack_channel_setting_audit slack_configuration_actions slack_configuration_sessions
    slack_incident_room_lifecycle_events slack_incident_rooms slack_interaction_audit
    slack_settings slack_source_audits slack_task_cards slack_thread_status_receipts
    slack_thread_statuses standing_assignment_runs standing_rule_inventories
    webhook_source_settings work_candidate_responses work_input_artifact_references
    work_output_artifacts work_settings
  )

  # Whatever carries the trigger now, found by name: a table dropped since the
  # baseline took its trigger with it.
  def up do
    execute("""
    DO $$
    DECLARE
      changed record;
    BEGIN
      FOR changed IN
        SELECT DISTINCT relation.relname AS name
        FROM pg_trigger AS trigger
        JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE trigger.tgname = 'ryker_control_plane_changed'
          AND namespace.nspname = #{literal(schema())}
      LOOP
        EXECUTE format('DROP TRIGGER ryker_control_plane_changed ON %I.%I', #{literal(schema())}, changed.name);
      END LOOP;
    END
    $$
    """)

    execute("DROP FUNCTION #{qualified("ryker_control_plane_notify")}()")
  end

  def down do
    execute("""
    CREATE FUNCTION #{qualified("ryker_control_plane_notify")}() RETURNS trigger
        LANGUAGE plpgsql
        AS $$
    BEGIN
      PERFORM pg_notify('ryker_control_plane', TG_TABLE_NAME);
      RETURN NULL;
    END;
    $$
    """)

    execute("""
    DO $$
    DECLARE
      name text;
    BEGIN
      FOREACH name IN ARRAY ARRAY[#{Enum.map_join(@tables, ", ", &literal/1)}] LOOP
        IF to_regclass(format('%I.%I', #{literal(schema())}, name)) IS NOT NULL THEN
          EXECUTE format(
            'CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR DELETE OR UPDATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION %I.ryker_control_plane_notify()',
            #{literal(schema())}, name, #{literal(schema())}
          );
        END IF;
      END LOOP;
    END
    $$
    """)
  end

  defp schema, do: prefix() || "public"

  defp qualified(name),
    do: ~s("#{String.replace(schema(), "\"", "\"\"")}"."#{name}")

  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
