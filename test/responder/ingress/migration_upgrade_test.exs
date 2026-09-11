defmodule Responder.Ingress.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Responder.{CanonicalJSON, Release}
  alias Responder.State.{ConversationKnowledge, KnowledgeRevision, KnowledgeSource}

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :responder,
      adapter: Ecto.Adapters.Postgres
  end

  @legacy_version 20_260_827_000_200
  @work_custody_version 20_260_828_000_100
  @product_schema_version 20_260_830_000_100
  @cutover_ledger_version 20_260_830_000_200
  @runtime_progress_version 20_260_830_000_300
  @artifact_references_version 20_260_830_000_400
  @lab_post_capability_version 20_260_830_000_500
  @reaction_events_version 20_260_830_000_600
  @work_classes_version 20_260_903_000_100
  @authority_digests_version 20_260_903_000_200
  @slack_thread_statuses_version 20_260_904_000_100
  @operator_actions_version 20_260_904_000_200
  @publication_recovery_version 20_260_904_000_300
  @publication_stale_head_version 20_260_904_000_400
  @conversation_continuity_version 20_260_904_000_500
  @repository_contexts_version 20_260_904_000_600
  @event_subscriptions_version 20_260_904_000_700
  @work_activity_version 20_260_904_000_800
  @card_lab_feedback_version 20_260_904_000_900
  @timer_resolution_version 20_260_907_000_200
  @wait_scheduling_errors_version 20_260_907_000_300
  @slack_addressing_version 20_260_907_000_400
  @candidate_responses_version 20_260_907_000_500
  @bounded_sources_version 20_260_909_000_100
  @confirmed_slack_feedback_version 20_260_909_000_200
  @event_only_waits_version 20_260_909_120_000
  @completion_receipts_version 20_260_909_160_000
  @model_instructions_version 20_260_910_000_100
  @wait_list_order_version 20_260_910_000_200
  @typed_question_answers_version 20_260_910_000_300
  @answer_confirmed_global_facts_version 20_260_910_000_400
  @worker_storage_reports_version 20_260_911_000_400
  @selected_work_inputs_version 20_260_911_000_100
  @rule_inventories_version 20_260_911_000_200
  @source_envelopes_version 20_260_911_000_300
  @engagement_receipts_version 20_260_911_000_500
  @default_channel_configurations_version 20_260_911_000_700
  @latest_versions [
    @typed_question_answers_version,
    @answer_confirmed_global_facts_version,
    @selected_work_inputs_version,
    @rule_inventories_version,
    @source_envelopes_version,
    @worker_storage_reports_version,
    @engagement_receipts_version,
    @default_channel_configurations_version
  ]
  @memory_versions Enum.to_list(20_260_908_000_100..20_260_908_001_100//100) ++
                     [@bounded_sources_version]
  @workspace_versions [
    20_260_905_000_100,
    20_260_905_000_200,
    20_260_905_000_300,
    20_260_905_000_400,
    20_260_905_000_500,
    20_260_906_001_000,
    20_260_906_002_000,
    20_260_906_004_000,
    20_260_907_000_100,
    @timer_resolution_version,
    @wait_scheduling_errors_version,
    @slack_addressing_version,
    @candidate_responses_version
  ]
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)

  test "an installation that already ran the Slack inbox migration upgrades to generic ingress" do
    repo = start_migration_repo!()
    prefix = "ingress_upgrade_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @legacy_version,
               prefix: prefix,
               log: false
             ) == [20_260_827_000_100, @legacy_version]

      assert table_exists?(repo, prefix, "slack_inbox_entries")
      refute table_exists?(repo, prefix, "ingress_inbox_entries")

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               all: true,
               prefix: prefix,
               log: false
             ) == [
               20_260_827_000_300,
               20_260_827_000_400,
               20_260_828_000_100,
               @product_schema_version,
               @cutover_ledger_version,
               @runtime_progress_version,
               @artifact_references_version,
               @lab_post_capability_version,
               @reaction_events_version,
               @work_classes_version,
               @authority_digests_version,
               @slack_thread_statuses_version,
               @operator_actions_version,
               @publication_recovery_version,
               @publication_stale_head_version,
               @conversation_continuity_version,
               @repository_contexts_version,
               @event_subscriptions_version,
               @work_activity_version,
               @card_lab_feedback_version
               | @workspace_versions ++
                   @memory_versions ++
                   [
                     @confirmed_slack_feedback_version,
                     @event_only_waits_version,
                     @completion_receipts_version,
                     @model_instructions_version,
                     @wait_list_order_version
                   ] ++ @latest_versions
             ]

      refute table_exists?(repo, prefix, "slack_inbox_entries")
      assert table_exists?(repo, prefix, "ingress_inbox_entries")
      assert table_exists?(repo, prefix, "model_instruction_settings")
      assert table_exists?(repo, prefix, "model_instruction_edits")
      assert table_exists?(repo, prefix, "episode_publications")
      assert table_exists?(repo, prefix, "episode_schedules")
      assert table_exists?(repo, prefix, "operator_behaviors")
      assert table_exists?(repo, prefix, "standing_assignment_runs")
      assert table_exists?(repo, prefix, "operational_memory_entries")
      assert table_exists?(repo, prefix, "slack_channel_setting_overrides")
      assert table_exists?(repo, prefix, "slack_channel_setting_audit")
      assert table_exists?(repo, prefix, "slack_channel_memberships")
      assert table_exists?(repo, prefix, "slack_channel_membership_events")
      assert table_exists?(repo, prefix, "slack_channel_configurations")
      assert table_exists?(repo, prefix, "slack_configuration_sessions")
      assert table_exists?(repo, prefix, "slack_configuration_actions")
      assert table_exists?(repo, prefix, "slack_incident_rooms")
      assert table_exists?(repo, prefix, "slack_incident_room_lifecycle_events")
      assert table_exists?(repo, prefix, "slack_task_cards")
      assert table_exists?(repo, prefix, "slack_thread_statuses")
      assert table_exists?(repo, prefix, "responder_operator_actions")
      assert table_exists?(repo, prefix, "slack_interaction_audit")
      assert table_exists?(repo, prefix, "retention_operator_actions")
      assert table_exists?(repo, prefix, "episode_emisar_approvals")
      assert column_exists?(repo, prefix, "ingress_inbox_entries", "execution_mode")
      assert column_exists?(repo, prefix, "episode_kernel_episodes", "execution_mode")
      assert column_exists?(repo, prefix, "ingress_inbox_entries", "work_policy")
      assert column_exists?(repo, prefix, "ingress_inbox_entries", "work_profile")
      assert column_exists?(repo, prefix, "episode_work_sessions", "repository_ref")
      assert column_exists?(repo, prefix, "episode_work_sessions", "cleanup_status")
      assert column_exists?(repo, prefix, "episode_work_sessions", "cleanup_blocked_from")
      assert column_exists?(repo, prefix, "episode_work_sessions", "authority_digest")
      assert column_exists?(repo, prefix, "coop_workers", "policy_authority_digests")
      assert column_exists?(repo, prefix, "ingress_inbox_entries", "operational_pruned_at")
      assert column_exists?(repo, prefix, "episode_work_turns", "operational_pruned_at")
      assert column_exists?(repo, prefix, "episode_kernel_episodes", "history_pruned_at")
      assert column_exists?(repo, prefix, "episode_schedules", "revision")
      assert column_exists?(repo, prefix, "operator_behaviors", "revision")
      assert table_exists?(repo, prefix, "coop_worker_workspace_checkpoints")
      assert table_exists?(repo, prefix, "responder_cutover_runs")
      assert table_exists?(repo, prefix, "responder_cutover_items")
      assert table_exists?(repo, prefix, "responder_runtime_progress")
      assert table_exists?(repo, prefix, "ingress_input_artifact_references")
      assert table_exists?(repo, prefix, "work_input_artifact_references")
      assert table_exists?(repo, prefix, "conversation_summary_drafts")
      assert table_exists?(repo, prefix, "conversation_summaries")
      assert table_exists?(repo, prefix, "conversation_rollups")
      assert table_exists?(repo, prefix, "memory_review_items")
      assert table_exists?(repo, prefix, "episode_work_activity")
      assert table_exists?(repo, prefix, "card_lab_feedback")
      assert table_exists?(repo, prefix, "work_candidate_responses")
      assert table_exists?(repo, prefix, "conversation_learning_batches")
      assert table_exists?(repo, prefix, "conversation_learning_inputs")
      assert column_exists?(repo, prefix, "episode_work_sessions", "learning_run_id")
      assert column_exists?(repo, prefix, "conversation_knowledge_sources", "receipt")
      assert column_exists?(repo, prefix, "episode_work_sessions", "activity_cursor")

      assert constraint_definition(
               repo,
               prefix,
               "coop_worker_events",
               "coop_worker_event_identity_valid"
             ) =~ "session_event"

      assert column_exists?(
               repo,
               prefix,
               "episode_work_turns",
               "final_preflight_continuity_sha256"
             )

      assert cascading_foreign_key?(
               repo,
               prefix,
               "coop_worker_workspace_checkpoint_command_worker_fkey"
             )
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "populated Stage 3 custody survives the reversible product upgrade, rollback, and re-upgrade" do
    repo = start_migration_repo!()
    prefix = "product_schema_round_trip_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @candidate_responses_version,
               prefix: prefix,
               log: false
             ) == [
               @product_schema_version,
               @cutover_ledger_version,
               @runtime_progress_version,
               @artifact_references_version,
               @lab_post_capability_version,
               @reaction_events_version,
               @work_classes_version,
               @authority_digests_version,
               @slack_thread_statuses_version,
               @operator_actions_version,
               @publication_recovery_version,
               @publication_stale_head_version,
               @conversation_continuity_version,
               @repository_contexts_version,
               @event_subscriptions_version,
               @work_activity_version,
               @card_lab_feedback_version
               | @workspace_versions
             ]

      assert_upgraded_rows!(repo, prefix, ids)
      assert_authority_fields!(repo, prefix, ids)

      admission_session_id = insert_admission_session!(repo, prefix)

      assert %{rows: [["admission", nil]]} =
               SQL.query!(
                 repo,
                 "SELECT execution_kind, episode_id FROM #{prefix}.episode_work_sessions WHERE id = $1::text::uuid",
                 [admission_session_id]
               )

      rollback_card_lab_feedback!(repo, prefix)

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@work_activity_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@event_subscriptions_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@repository_contexts_version]

      refute column_exists?(repo, prefix, "episode_work_sessions", "repository_context")
      refute column_exists?(repo, prefix, "slack_incident_rooms", "repository_context")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@conversation_continuity_version]

      refute table_exists?(repo, prefix, "conversation_summaries")

      refute column_exists?(
               repo,
               prefix,
               "episode_work_turns",
               "final_preflight_continuity_sha256"
             )

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@publication_stale_head_version]

      refute column_exists?(repo, prefix, "episode_publications", "expected_remote_head_sha")
      assert column_exists?(repo, prefix, "episode_publications", "recovery_generation")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@publication_recovery_version]

      refute column_exists?(repo, prefix, "episode_publications", "recovery_generation")
      assert table_exists?(repo, prefix, "responder_operator_actions")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@operator_actions_version]

      refute table_exists?(repo, prefix, "responder_operator_actions")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@slack_thread_statuses_version]

      refute table_exists?(repo, prefix, "slack_thread_statuses")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@authority_digests_version]

      refute column_exists?(repo, prefix, "episode_work_sessions", "authority_digest")
      refute column_exists?(repo, prefix, "coop_workers", "policy_authority_digests")
      assert column_exists?(repo, prefix, "ingress_inbox_entries", "work_profile")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@work_classes_version]

      refute column_exists?(repo, prefix, "ingress_inbox_entries", "work_profile")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@reaction_events_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@lab_post_capability_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@artifact_references_version]

      refute table_exists?(repo, prefix, "ingress_input_artifact_references")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@runtime_progress_version]

      refute table_exists?(repo, prefix, "responder_runtime_progress")

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@cutover_ledger_version]

      assert_upgraded_rows!(repo, prefix, ids)

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@product_schema_version]

      assert_stage3_rows!(repo, prefix, ids)

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @candidate_responses_version,
               prefix: prefix,
               log: false
             ) == [
               @product_schema_version,
               @cutover_ledger_version,
               @runtime_progress_version,
               @artifact_references_version,
               @lab_post_capability_version,
               @reaction_events_version,
               @work_classes_version,
               @authority_digests_version,
               @slack_thread_statuses_version,
               @operator_actions_version,
               @publication_recovery_version,
               @publication_stale_head_version,
               @conversation_continuity_version,
               @repository_contexts_version,
               @event_subscriptions_version,
               @work_activity_version,
               @card_lab_feedback_version
               | @workspace_versions
             ]

      assert_upgraded_rows!(repo, prefix, ids)
      assert_authority_fields!(repo, prefix, ids)
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "the release migrator rolls back only the expected version of a pinned reversible release" do
    temporary = migration_temporary_directory!()
    repo = start_migration_repo!()
    prefix = "release_migrator_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    # A historical rollback must use that release's exact migration set. Applying
    # a later, explicitly irreversible memory reset is not historical setup.
    migrations_path = historical_migrations!(temporary)
    options = [repo: repo, prefix: prefix, migrations_path: migrations_path, log: false]

    try do
      assert Release.migrate(options) == [
               20_260_827_000_100,
               20_260_827_000_200,
               20_260_827_000_300,
               20_260_827_000_400,
               20_260_828_000_100,
               @product_schema_version,
               @cutover_ledger_version,
               @runtime_progress_version,
               @artifact_references_version,
               @lab_post_capability_version,
               @reaction_events_version,
               @work_classes_version,
               @authority_digests_version,
               @slack_thread_statuses_version,
               @operator_actions_version,
               @publication_recovery_version,
               @publication_stale_head_version,
               @conversation_continuity_version,
               @repository_contexts_version,
               @event_subscriptions_version,
               @work_activity_version,
               @card_lab_feedback_version
               | @workspace_versions
             ]

      assert Release.migrate(options) == []

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@work_custody_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@product_schema_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@cutover_ledger_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@work_classes_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@authority_digests_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@slack_thread_statuses_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@operator_actions_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@publication_recovery_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@publication_stale_head_version, options)
      end

      assert_raise ArgumentError, ~r/latest applied migration.*does not match/, fn ->
        Release.rollback(@conversation_continuity_version, options)
      end

      for version <- Enum.reverse(@workspace_versions) do
        assert Release.rollback(version, options) == [version]
      end

      assert Release.rollback(@card_lab_feedback_version, options) == [
               @card_lab_feedback_version
             ]

      refute table_exists?(repo, prefix, "card_lab_feedback")

      assert Release.rollback(@work_activity_version, options) == [
               @work_activity_version
             ]

      assert Release.rollback(@event_subscriptions_version, options) == [
               @event_subscriptions_version
             ]

      assert Release.rollback(@repository_contexts_version, options) == [
               @repository_contexts_version
             ]

      refute column_exists?(repo, prefix, "episode_work_sessions", "repository_context")
      refute column_exists?(repo, prefix, "slack_incident_rooms", "repository_context")

      assert Release.rollback(@conversation_continuity_version, options) == [
               @conversation_continuity_version
             ]

      refute table_exists?(repo, prefix, "conversation_summaries")

      assert Release.rollback(@publication_stale_head_version, options) == [
               @publication_stale_head_version
             ]

      refute column_exists?(repo, prefix, "episode_publications", "expected_remote_head_sha")
      assert column_exists?(repo, prefix, "episode_publications", "recovery_generation")

      assert Release.rollback(@publication_recovery_version, options) == [
               @publication_recovery_version
             ]

      refute column_exists?(repo, prefix, "episode_publications", "recovery_generation")
      assert table_exists?(repo, prefix, "responder_operator_actions")

      assert Release.rollback(@operator_actions_version, options) == [
               @operator_actions_version
             ]

      refute table_exists?(repo, prefix, "responder_operator_actions")

      assert Release.rollback(@slack_thread_statuses_version, options) == [
               @slack_thread_statuses_version
             ]

      refute table_exists?(repo, prefix, "slack_thread_statuses")

      assert Release.rollback(@authority_digests_version, options) == [
               @authority_digests_version
             ]

      refute column_exists?(repo, prefix, "episode_work_sessions", "authority_digest")
      refute column_exists?(repo, prefix, "coop_workers", "policy_authority_digests")

      assert Release.rollback(@work_classes_version, options) == [
               @work_classes_version
             ]

      assert Release.rollback(@reaction_events_version, options) == [
               @reaction_events_version
             ]

      assert Release.rollback(@lab_post_capability_version, options) == [
               @lab_post_capability_version
             ]

      assert Release.rollback(@artifact_references_version, options) == [
               @artifact_references_version
             ]

      refute table_exists?(repo, prefix, "ingress_input_artifact_references")

      assert Release.rollback(@runtime_progress_version, options) == [@runtime_progress_version]
      refute table_exists?(repo, prefix, "responder_runtime_progress")

      assert Release.rollback(@cutover_ledger_version, options) == [@cutover_ledger_version]
      refute table_exists?(repo, prefix, "responder_cutover_runs")
      assert table_exists?(repo, prefix, "episode_publications")

      assert Release.rollback(@product_schema_version, options) == [@product_schema_version]
      refute table_exists?(repo, prefix, "episode_publications")
      assert table_exists?(repo, prefix, "episode_work_sessions")
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "publication recovery migrations refuse to discard feature data on rollback" do
    repo = start_migration_repo!()
    prefix = "publication_recovery_rollback_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      rollback_card_lab_feedback!(repo, prefix)

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@work_activity_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@event_subscriptions_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@repository_contexts_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@conversation_continuity_version]

      {record_id, publication_id} = insert_stale_head_recovery_rows!(repo, prefix, ids)

      assert_raise Postgrex.Error, ~r/stale-head recovery has data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert column_exists?(repo, prefix, "episode_publications", "expected_remote_head_sha")

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.episode_publications WHERE id = $1::text::uuid",
        [publication_id]
      )

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.episode_state_records WHERE id = $1::text::uuid",
        [record_id]
      )

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@publication_stale_head_version]

      insert_publication_recovery_action!(repo, prefix)

      assert_raise Postgrex.Error, ~r/publication recovery has data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert column_exists?(repo, prefix, "episode_publications", "recovery_generation")

      assert %{rows: [["update"]]} =
               SQL.query!(repo, "SELECT action FROM #{prefix}.responder_operator_actions", [])
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "conversation continuity migration refuses to discard feature data on rollback" do
    repo = start_migration_repo!()
    prefix = "conversation_continuity_rollback_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      rollback_card_lab_feedback!(repo, prefix)

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@work_activity_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@event_subscriptions_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@repository_contexts_version]

      review_id = Ecto.UUID.generate()

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.memory_review_items (
          id, ref, workspace_ref, kind, entry_refs, reason, source_digest, status,
          inserted_at, updated_at
        ) VALUES (
          $1::text::uuid, $2, 'slack:T123', 'stale', '[]', 'retention review', $3,
          'pending', clock_timestamp(), clock_timestamp()
        )
        """,
        [review_id, "memory-review:#{review_id}", String.duplicate("a", 64)]
      )

      assert_raise Postgrex.Error, ~r/conversation continuity has data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert table_exists?(repo, prefix, "memory_review_items")
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "repository context migration refuses to discard frozen placement on rollback" do
    repo = start_migration_repo!()
    prefix = "repository_context_rollback_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      rollback_card_lab_feedback!(repo, prefix)

      context =
        Jason.encode!(%{
          "context_ref" => "platform",
          "parallel_goal_limit" => 2,
          "primary_repository" => "responder",
          "read_only_repositories" => ["emisar"]
        })

      SQL.query!(
        repo,
        "UPDATE #{prefix}.episode_work_sessions SET repository_ref = 'responder', repository_context = $1 WHERE id = $2::text::uuid",
        [context, ids.session_id]
      )

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@work_activity_version]

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@event_subscriptions_version]

      assert_raise Postgrex.Error, ~r/repository context has data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert column_exists?(repo, prefix, "episode_work_sessions", "repository_context")
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "event subscription migration refuses to discard durable polling custody" do
    repo = start_migration_repo!()
    prefix = "event_subscription_rollback_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      rollback_card_lab_feedback!(repo, prefix)

      assert Ecto.Migrator.run(repo, @migrations_path, :down,
               step: 1,
               prefix: prefix,
               log: false
             ) == [@work_activity_version]

      record_id = Ecto.UUID.generate()
      subscription_id = Ecto.UUID.generate()

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.episode_state_records (
          id, episode_id, turn_id, ref, operation_id, kind, status, payload,
          payload_fingerprint, sequence, inserted_at, updated_at
        ) VALUES (
          $1::text::uuid, $2::text::uuid, $3::text::uuid,
          'record:event-wait:rollback', 'wait-rollback', 'event_wait', 'open',
          '{"deadline_at":"2099-01-01T01:00:00Z","event_matcher":{},"kind":"source_event","verification":"verify"}',
          repeat('d', 64), 1, clock_timestamp(), clock_timestamp()
        )
        """,
        [record_id, ids.episode_id, ids.turn_id]
      )

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.episode_event_subscriptions (
          id, episode_id, record_id, ref, status, source_kind, matcher, cursor,
          poll_after, deadline_at, revision, inserted_at, updated_at
        ) VALUES (
          $1::text::uuid, $2::text::uuid, $3::text::uuid,
          'event-subscription:rollback', 'active', 'github', '{"state":"healthy"}',
          '{"revision":"abc123"}', '2099-01-01T00:30:00Z', '2099-01-01T01:00:00Z',
          1, clock_timestamp(), clock_timestamp()
        )
        """,
        [subscription_id, ids.episode_id, record_id]
      )

      assert_raise Postgrex.Error, ~r/subscription or manual schedule history has data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert table_exists?(repo, prefix, "episode_event_subscriptions")
      assert column_exists?(repo, prefix, "episode_schedule_occurrences", "trigger")
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "timer resolution migration preserves polling custody and refuses to erase timer history" do
    # Timer wake-ups need a distinct resolution; rollback must not relabel them as source events.
    repo = start_migration_repo!()
    prefix = "timer_resolution_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: 20_260_907_000_100,
        prefix: prefix,
        log: false
      )

      insert_wait_migration_rows!(repo, prefix, ids)
      snapshot_query = "SELECT * FROM #{prefix}.episode_event_subscriptions"
      original = SQL.query!(repo, snapshot_query, []).rows

      timer_query =
        "UPDATE #{prefix}.episode_event_subscriptions SET status = 'resolved', resolution_kind = 'timer'"

      assert_raise Postgrex.Error, ~r/episode_event_subscription_valid/, fn ->
        SQL.query!(repo, timer_query, [])
      end

      for direction <- [:up, :down, :up] do
        assert Ecto.Migrator.run(repo, @migrations_path, direction,
                 step: 1,
                 prefix: prefix,
                 log: false
               ) == [@timer_resolution_version]

        assert SQL.query!(repo, snapshot_query, []).rows == original
      end

      for {status, resolution} <- [
            {"resolved", "input"},
            {"resolved", "poll_fallback"},
            {"timed_out", "deadline"},
            {"cancelled", "cancelled"}
          ] do
        assert %{num_rows: 1} =
                 SQL.query!(
                   repo,
                   "UPDATE #{prefix}.episode_event_subscriptions SET status = $1, resolution_kind = $2",
                   [status, resolution]
                 )
      end

      assert %{num_rows: 1} = SQL.query!(repo, timer_query, [])
      timer_history = SQL.query!(repo, snapshot_query, []).rows

      for {status, resolution} <- [
            {"active", "timer"},
            {"timed_out", "timer"},
            {"cancelled", "timer"},
            {"resolved", "deadline"},
            {"resolved", "unknown"}
          ] do
        assert_raise Postgrex.Error, ~r/episode_event_subscription_valid/, fn ->
          SQL.query!(
            repo,
            "UPDATE #{prefix}.episode_event_subscriptions SET status = $1, resolution_kind = $2",
            [status, resolution]
          )
        end
      end

      assert_raise Postgrex.Error,
                   ~r/timer resolution history cannot be rolled back safely/,
                   fn ->
                     Ecto.Migrator.run(repo, @migrations_path, :down,
                       step: 1,
                       prefix: prefix,
                       log: false
                     )
                   end

      assert SQL.query!(repo, snapshot_query, []).rows == timer_history

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @timer_resolution_version,
               prefix: prefix,
               log: false
             ) == []
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "wait scheduling diagnostics are bounded and survive refused rollback without changing records" do
    # A down migration must not turn a retained scheduling failure into an unexplained wait.
    repo = start_migration_repo!()
    prefix = "wait_diagnostics_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @timer_resolution_version,
        prefix: prefix,
        log: false
      )

      insert_wait_migration_rows!(repo, prefix, ids)

      snapshot_query =
        "SELECT id, episode_id, turn_id, payload, payload_fingerprint, status, inserted_at FROM #{prefix}.episode_state_records"

      original = SQL.query!(repo, snapshot_query, []).rows

      for direction <- [:up, :down, :up] do
        assert Ecto.Migrator.run(repo, @migrations_path, direction,
                 step: 1,
                 prefix: prefix,
                 log: false
               ) == [@wait_scheduling_errors_version]

        assert column_exists?(repo, prefix, "episode_state_records", "wait_error") ==
                 (direction == :up)

        assert SQL.query!(repo, snapshot_query, []).rows == original
      end

      assert %{rows: [[nil]]} =
               SQL.query!(repo, "SELECT wait_error FROM #{prefix}.episode_state_records", [])

      for error <- ~w(deadline poll_after timer_deadline source_kind cursor) do
        assert %{num_rows: 1} =
                 SQL.query!(repo, "UPDATE #{prefix}.episode_state_records SET wait_error = $1", [
                   error
                 ])

        assert %{rows: [[^error]]} =
                 SQL.query!(repo, "SELECT wait_error FROM #{prefix}.episode_state_records", [])
      end

      for query <- [
            "UPDATE #{prefix}.episode_state_records SET wait_error = 'unknown'",
            "UPDATE #{prefix}.episode_state_records SET wait_error = ''",
            "UPDATE #{prefix}.episode_state_records SET kind = 'finding'"
          ] do
        assert_raise Postgrex.Error, ~r/episode_state_record_wait_error_valid/, fn ->
          SQL.query!(repo, query, [])
        end
      end

      assert SQL.query!(repo, snapshot_query, []).rows == original

      assert_raise Postgrex.Error,
                   ~r/wait scheduling diagnostics cannot be rolled back safely/,
                   fn ->
                     Ecto.Migrator.run(repo, @migrations_path, :down,
                       step: 1,
                       prefix: prefix,
                       log: false
                     )
                   end

      assert SQL.query!(repo, snapshot_query, []).rows == original

      assert %{rows: [["cursor"]]} =
               SQL.query!(repo, "SELECT wait_error FROM #{prefix}.episode_state_records", [])

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @wait_scheduling_errors_version,
               prefix: prefix,
               log: false
             ) == []
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "Slack addressing migration preserves absent history and refuses to discard present metadata" do
    # Old receipts cannot acquire a guessed bot identity; recorded addressing must survive rollback.
    repo = start_migration_repo!()
    prefix = "slack_addressing_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @wait_scheduling_errors_version,
        prefix: prefix,
        log: false
      )

      snapshot_query =
        "SELECT id, event_fingerprint, content, admission_context, inserted_at FROM #{prefix}.ingress_inbox_entries"

      original = SQL.query!(repo, snapshot_query, []).rows

      for direction <- [:up, :down, :up] do
        assert Ecto.Migrator.run(repo, @migrations_path, direction,
                 step: 1,
                 prefix: prefix,
                 log: false
               ) == [@slack_addressing_version]

        assert column_exists?(repo, prefix, "ingress_inbox_entries", "slack_audience") ==
                 (direction == :up)

        assert SQL.query!(repo, snapshot_query, []).rows == original
      end

      assert %{rows: [[nil, nil]]} =
               SQL.query!(
                 repo,
                 "SELECT slack_audience, slack_bot_user_ref FROM #{prefix}.ingress_inbox_entries",
                 []
               )

      for {audience, user_ref} <- [
            {"mention", nil},
            {nil, "UBOT"},
            {"unknown", "UBOT"},
            {"", "UBOT"},
            {"direct", ""},
            {"ambient", "UBOT\n"},
            {"ambient", " U1"},
            {"ambient", "ÜBOT"},
            {"mention", String.duplicate("U", 257)}
          ] do
        assert_raise Postgrex.Error, ~r/ingress_inbox_slack_addressing_valid/, fn ->
          SQL.query!(
            repo,
            "UPDATE #{prefix}.ingress_inbox_entries SET slack_audience = $1, slack_bot_user_ref = $2",
            [audience, user_ref]
          )
        end
      end

      for audience <- ~w(ambient direct mention) do
        assert %{num_rows: 1} =
                 SQL.query!(
                   repo,
                   "UPDATE #{prefix}.ingress_inbox_entries SET slack_audience = $1, slack_bot_user_ref = $2",
                   [audience, String.duplicate("U", 256)]
                 )
      end

      assert_raise Postgrex.Error, ~r/ingress_inbox_slack_addressing_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.ingress_inbox_entries SET source_kind = 'webhook', source_capabilities = '{}'",
          []
        )
      end

      assert_raise Postgrex.Error,
                   ~r/Slack addressing history cannot be rolled back safely/,
                   fn ->
                     Ecto.Migrator.run(repo, @migrations_path, :down,
                       step: 1,
                       prefix: prefix,
                       log: false
                     )
                   end

      assert SQL.query!(repo, snapshot_query, []).rows == original

      assert %{rows: [["mention", user_ref]]} =
               SQL.query!(
                 repo,
                 "SELECT slack_audience, slack_bot_user_ref FROM #{prefix}.ingress_inbox_entries",
                 []
               )

      assert byte_size(user_ref) == 256

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @candidate_responses_version,
               prefix: prefix,
               log: false
             ) ==
               [@candidate_responses_version]
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "candidate response history survives refused rollback after an empty migration round trip" do
    # Missing older response bytes made repair history impossible to inspect. Rolling back
    # must not recreate that loss; this is host setup using an actually retained raw candidate.
    repo = start_migration_repo!()
    prefix = "candidate_responses_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @slack_addressing_version,
        prefix: prefix,
        log: false
      )

      owner_query = "SELECT * FROM #{prefix}.episode_work_turns"
      owner = SQL.query!(repo, owner_query, []).rows

      for direction <- [:up, :down, :up] do
        assert Ecto.Migrator.run(repo, @migrations_path, direction,
                 step: 1,
                 prefix: prefix,
                 log: false
               ) == [@candidate_responses_version]

        assert table_exists?(repo, prefix, "work_candidate_responses") == (direction == :up)
        assert SQL.query!(repo, owner_query, []).rows == owner
      end

      [_, response] =
        __DIR__
        |> Path.join("../work/fixtures/airflow_candidate_responses.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("responses")

      %{"body" => body, "sha256" => sha256, "bytes" => bytes} = response

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.work_candidate_responses
          (turn_id, candidate_attempt, body, sha256, byte_size, recorded_at)
        VALUES ($1::text::uuid, 1, $2, $3, $4, clock_timestamp())
        """,
        [ids.turn_id, body, sha256, bytes]
      )

      response_query = "SELECT * FROM #{prefix}.work_candidate_responses"
      original = SQL.query!(repo, response_query, []).rows

      assert_raise Postgrex.Error, ~r/export candidate response history before rollback/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert SQL.query!(repo, response_query, []).rows == original
      assert SQL.query!(repo, owner_query, []).rows == owner

      assert %{rows: [[^body, ^sha256, ^bytes, nil]]} =
               SQL.query!(
                 repo,
                 "SELECT body, sha256, byte_size, operational_pruned_at FROM #{prefix}.work_candidate_responses",
                 []
               )

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @candidate_responses_version,
               prefix: prefix,
               log: false
             ) ==
               []
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "work activity migration refuses to discard durable narration on rollback" do
    repo = start_migration_repo!()
    prefix = "work_activity_rollback_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      rollback_card_lab_feedback!(repo, prefix)

      event_id = Ecto.UUID.generate()

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.episode_work_activity (
          id, episode_id, session_id, remote_event_id, remote_session_id, sequence, kind, version,
          occurred_at, payload, payload_fingerprint, inserted_at
        ) VALUES (
          $1::text::uuid, $2::text::uuid, $3::text::uuid, $4, $5, 1, 'model.thought', 1,
          clock_timestamp(), '{}', repeat('a', 64), clock_timestamp()
        )
        """,
        [
          event_id,
          ids.episode_id,
          ids.session_id,
          "activity-event:#{event_id}",
          "remote-session:#{ids.session_id}"
        ]
      )

      assert_raise Postgrex.Error, ~r/episode work activity has data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert table_exists?(repo, prefix, "episode_work_activity")
      assert column_exists?(repo, prefix, "episode_work_sessions", "activity_cursor")
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "card lab feedback migration refuses to discard operator review on rollback" do
    repo = start_migration_repo!()
    prefix = "card_lab_feedback_rollback_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      rollback_workspace!(repo, prefix)

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.card_lab_feedback (
          id, actor_ref, card_id, state_id, verdict, note, inserted_at
        ) VALUES (
          $1::text::uuid, 'control-plane:operator', 'task-card', 'working',
          'needs_work', 'The hierarchy needs another pass.', clock_timestamp()
        )
        """,
        [Ecto.UUID.generate()]
      )

      assert_raise Postgrex.Error, ~r/card lab feedback has data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert table_exists?(repo, prefix, "card_lab_feedback")
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "conversation memory survives a refused rollback and invalidates its live reader" do
    # A rollback must not silently erase the knowledge learned from ignored messages.
    repo = start_migration_repo!()
    prefix = "observations_rollback_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.conversation_observations
          (id, identity_key, transport, workspace_ref, conversation_ref, visibility,
           source_input_id, source_message_ref, source_result_ref, source_fingerprint, actor_ref,
           execution_mode, revision, occurred_at, note, inserted_at, updated_at)
        VALUES ($1::text::uuid, 'source', 'slack', 'slack:T', 'slack:T:C', 'public',
                $1::text::uuid, '1787832000.000100', 'result', 'fingerprint', 'U',
                'shadow', 1, clock_timestamp(), '{"summary":"Keep the service","topics":[]}',
                clock_timestamp(), clock_timestamp())
        """,
        [Ecto.UUID.generate()]
      )

      assert_raise Postgrex.Error, ~r/conversation observations have data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          to: 20_260_906_002_000,
          prefix: prefix,
          log: false
        )
      end

      assert %{rows: [[1]]} =
               SQL.query!(repo, "SELECT count(*) FROM #{prefix}.conversation_observations", [])

      assert %{rows: [[true]]} =
               SQL.query!(
                 repo,
                 """
                 SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = $1::text::regclass
                   AND tgname = 'responder_control_plane_changed')
                 """,
                 [prefix <> ".conversation_observations"]
               )
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "source-only learning fences survive a refused rollback without a knowledge head" do
    repo = start_migration_repo!()
    prefix = "knowledge_lineage_rollback_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      id = Ecto.UUID.generate()
      sources = Jason.encode!([%{"source_input_id" => id, "revision" => 1}])

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.conversation_observations
          (id, identity_key, transport, workspace_ref, conversation_ref, visibility,
           source_input_id, source_message_ref, source_result_ref, source_fingerprint, actor_ref,
           execution_mode, revision, occurred_at, note, source_dependencies, inserted_at, updated_at)
        VALUES ($1::text::uuid, 'source', 'slack', 'slack:T', 'slack:T:C', 'public',
                $1::text::uuid, '1787832000.000100', 'result', repeat('a', 64), 'U',
                'shadow', 1, clock_timestamp(), '{"summary":"Keep the service","topics":[]}', $2,
                clock_timestamp(), clock_timestamp())
        """,
        [id, sources]
      )

      assert %{rows: [[0]]} =
               SQL.query!(repo, "SELECT count(*) FROM #{prefix}.conversation_knowledge", [])

      assert_raise Postgrex.Error, ~r/conversation learning has data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down,
          to: 20_260_906_004_000,
          prefix: prefix,
          log: false
        )
      end

      assert %{rows: [[^sources]]} =
               SQL.query!(
                 repo,
                 "SELECT source_dependencies FROM #{prefix}.conversation_observations",
                 []
               )

      assert table_exists?(repo, prefix, "episode_work_source_exposures")
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "the authorized memory reset preserves source and work custody and recovers from a real backup" do
    # A clean memory start must not erase episode history or disclosure fences.
    # These two irreversible cuts require a verified backup, not a fabricated down.
    temporary = migration_temporary_directory!()
    repo = start_migration_repo!()
    prefix = "memory_reset_upgrade_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      insert_stale_head_recovery_rows!(repo, prefix, ids)
      insert_memory_reset_rows!(repo, prefix, ids)

      preserved = reset_preserved_rows(repo, prefix)
      derived = reset_derived_rows(repo, prefix)
      assert %{rows: [[1, 1, 1]]} = reset_topic_counts(repo, prefix)
      backup = backup_schema!(repo, prefix, temporary)

      assert Ecto.Migrator.run(repo, @migrations_path, :up, all: true, prefix: prefix, log: false) ==
               @memory_versions ++
                 [
                   @confirmed_slack_feedback_version,
                   @event_only_waits_version,
                   @completion_receipts_version,
                   @model_instructions_version,
                   @wait_list_order_version
                 ] ++ @latest_versions

      # Existing sessions have unknown disclosure custody. New columns must not
      # falsely attest them as tracked source-free sessions during the upgrade.
      assert %{rows: [[0]]} =
               SQL.query!(
                 repo,
                 """
                 SELECT count(*) FROM #{prefix}.episode_work_sessions
                 WHERE source_exposure_count IS NOT NULL OR knowledge_exposure_count IS NOT NULL
                 """,
                 []
               )

      # Adding completion custody must not fabricate a receipt for historical work.
      assert %{rows: [[0]]} =
               SQL.query!(
                 repo,
                 "SELECT count(*) FROM #{prefix}.episode_work_turns WHERE completion_receipt IS NOT NULL",
                 []
               )

      assert reset_preserved_rows(repo, prefix) == preserved
      assert %{rows: [[0, 0, 0]]} = reset_topic_counts(repo, prefix)
      assert_reset_notes(repo, prefix, derived["conversation_observations"])

      # The inspection-evidence columns and tables, the worker storage columns and
      # the default channel configuration are reversible on their own.
      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 6, prefix: prefix, log: false) ==
               [
                 @default_channel_configurations_version,
                 @engagement_receipts_version,
                 @worker_storage_reports_version,
                 @source_envelopes_version,
                 @rule_inventories_version,
                 @selected_work_inputs_version
               ]

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 7, prefix: prefix, log: false) ==
               [
                 @answer_confirmed_global_facts_version,
                 @typed_question_answers_version,
                 @wait_list_order_version,
                 @model_instructions_version,
                 @completion_receipts_version,
                 @event_only_waits_version,
                 @confirmed_slack_feedback_version
               ]

      # The later indexes, exposure marker, rebuild fields and resolver are reversible;
      # the derived-note reset itself still requires the verified backup.
      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 4, prefix: prefix, log: false) ==
               @memory_versions |> Enum.take(-4) |> Enum.reverse()

      assert_raise RuntimeError, ~r/restore the qualified database backup/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
      end

      assert reset_preserved_rows(repo, prefix) == preserved
      assert_reset_notes(repo, prefix, derived["conversation_observations"])

      restore_schema!(repo, prefix, backup)
      assert reset_preserved_rows(repo, prefix) == preserved
      assert reset_derived_rows(repo, prefix) == derived
      assert %{rows: [[1, 1, 1]]} = reset_topic_counts(repo, prefix)

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: 20_260_908_000_200,
               prefix: prefix,
               log: false
             ) ==
               Enum.take(@memory_versions, 2)

      assert_raise RuntimeError, ~r/normalized memory cannot restore reset topic history/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
      end

      assert reset_preserved_rows(repo, prefix) == preserved

      restore_schema!(repo, prefix, backup)
      assert reset_preserved_rows(repo, prefix) == preserved
      assert reset_derived_rows(repo, prefix) == derived
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "typed answers and global facts refuse rollback only while their data exists" do
    # Both cuts are reversible on a schema that never used them; once a typed
    # answer or an answer-confirmed fact exists, rolling back would erase it.
    repo = start_migration_repo!()
    prefix = "answer_memory_rollback_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @work_custody_version,
        prefix: prefix,
        log: false
      )

      ids = insert_stage3_rows!(repo, prefix)

      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @candidate_responses_version,
        prefix: prefix,
        log: false
      )

      {record_id, _publication_id} = insert_stale_head_recovery_rows!(repo, prefix, ids)
      Ecto.Migrator.run(repo, @migrations_path, :up, all: true, prefix: prefix, log: false)
      assert column_nullable?(repo, prefix, "operational_memory_entries", "expires_at")
      assert column_nullable?(repo, prefix, "episode_state_record_responses", "choice")

      configuration_id = insert_default_channel_configuration!(repo, prefix)

      assert_raise Postgrex.Error, ~r/default channel configurations have data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
      end

      assert column_nullable?(repo, prefix, "slack_channel_configurations", "actor_ref")

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.slack_channel_configurations WHERE id = $1::text::uuid",
        [configuration_id]
      )

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@default_channel_configurations_version]

      refute column_exists?(repo, prefix, "slack_channel_configurations", "welcome_message_ref")
      refute column_nullable?(repo, prefix, "slack_channel_configurations", "actor_ref")

      # The inspection-evidence columns and tables and the worker storage columns
      # are reversible on their own.
      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 5, prefix: prefix, log: false) ==
               [
                 @engagement_receipts_version,
                 @worker_storage_reports_version,
                 @source_envelopes_version,
                 @rule_inventories_version,
                 @selected_work_inputs_version
               ]

      fact_id = insert_global_fact!(repo, prefix)

      assert_raise Postgrex.Error, ~r/global facts have data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
      end

      assert column_exists?(repo, prefix, "operational_memory_entries", "answer_provenance")

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.operational_memory_entries WHERE id = $1::text::uuid",
        [fact_id]
      )

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@answer_confirmed_global_facts_version]

      refute column_exists?(repo, prefix, "operational_memory_entries", "answer_provenance")
      refute column_nullable?(repo, prefix, "operational_memory_entries", "expires_at")

      response_id = insert_typed_answer!(repo, prefix, record_id, ids.ingress_id)

      assert_raise Postgrex.Error, ~r/typed question answers have data/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
      end

      assert column_nullable?(repo, prefix, "episode_state_record_responses", "choice")

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.episode_state_record_responses WHERE id = $1::text::uuid",
        [response_id]
      )

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@typed_question_answers_version]

      refute column_nullable?(repo, prefix, "episode_state_record_responses", "choice")

      assert Ecto.Migrator.run(repo, @migrations_path, :up, all: true, prefix: prefix, log: false) ==
               @latest_versions
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "bounding compact lookups preserves existing topic history and source roots on upgrade and rollback" do
    repo = start_migration_repo!()
    prefix = "bounded_sources_upgrade_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: 20_260_908_001_100,
        prefix: prefix,
        log: false
      )

      {reference, receipt} = insert_normalized_root!(repo, prefix)
      retained = reset_derived_rows(repo, prefix)

      for direction <- [:up, :down, :up] do
        assert Ecto.Migrator.run(repo, @migrations_path, direction,
                 step: 1,
                 prefix: prefix,
                 log: false
               ) == [@bounded_sources_version]

        assert reset_derived_rows(repo, prefix) == retained

        assert %{rows: [[^receipt]]} =
                 SQL.query!(
                   repo,
                   "SELECT #{prefix}.responder_learning_roots($1)",
                   [Jason.encode!([reference])]
                 )
      end
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp insert_normalized_root!(repo, prefix) do
    # Structural migration setup with unchanged harvested model prose. No live
    # source authorization is claimed; this checks existing byte preservation.
    captured =
      File.read!("testdata/learning/retained-draft-ai-suggestions-learning.json")
      |> Jason.decode!()

    state = captured["result"] |> Jason.decode!() |> Map.fetch!("updates") |> hd()
    now = DateTime.utc_now()
    id = Ecto.UUID.generate()

    reference = %{
      "kind" => "knowledge_sources",
      "knowledge_id" => id,
      "generation" => 1,
      "through_version" => 1
    }

    receipt = %{
      "observation_id" => Ecto.UUID.generate(),
      "source_input_id" => captured["input"]["id"],
      "revision" => captured["input"]["revision"],
      "fingerprint" => captured["input"]["event_fingerprint"],
      "retained_at" => DateTime.to_iso8601(now)
    }

    repo.insert!(
      %ConversationKnowledge{
        id: id,
        scope_key: "migration",
        topic_key: "retained-topic",
        transport: "slack",
        workspace_ref: "slack:T",
        conversation_ref: "slack:T:C",
        visibility: :public,
        state: state,
        version: 1,
        source_generation: 1,
        source_dependencies: [reference],
        source_input_id: receipt["source_input_id"],
        latest_source_at: now
      },
      prefix: prefix
    )

    repo.insert!(
      %KnowledgeRevision{
        knowledge_id: id,
        version: 1,
        source_generation: 1,
        source_dependencies: [reference],
        state: state,
        source_input_id: receipt["source_input_id"],
        source_result_ref: "migration:retained",
        source_at: now,
        inserted_at: now
      },
      prefix: prefix
    )

    repo.insert!(
      %KnowledgeSource{
        knowledge_id: id,
        observation_id: receipt["observation_id"],
        generation: 1,
        receipt_fingerprint: CanonicalJSON.digest(receipt),
        receipt: receipt,
        direct_support_version: 1,
        source_revision: receipt["revision"],
        source_fingerprint: receipt["fingerprint"],
        retained_at: now,
        introduced_version: 1
      },
      prefix: prefix
    )

    {reference, receipt}
  end

  defp insert_memory_reset_rows!(repo, prefix, ids) do
    captured =
      File.read!("testdata/learning/retained-draft-ai-suggestions-learning.json")
      |> Jason.decode!()

    state = captured["result"] |> Jason.decode!() |> Map.fetch!("updates") |> hd()
    state_json = Jason.encode!(state)
    note = Jason.encode!(Map.take(state, ~w(summary topics)))
    knowledge_id = Ecto.UUID.generate()
    observation_id = Ecto.UUID.generate()

    # Rows are structural migration fixtures; source/model prose is harvested unchanged.
    for {identity, source_result} <- [
          {"derived", "result:retained"},
          {"original", "input:#{ids.ingress_id}"}
        ] do
      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.conversation_observations
          (id, identity_key, transport, workspace_ref, conversation_ref, visibility,
           source_input_id, source_message_ref, source_result_ref, source_fingerprint,
           actor_ref, execution_mode, revision, occurred_at, note, inserted_at, updated_at)
        VALUES ($1::text::uuid, $2, 'slack', 'slack:T', 'slack:T:C', 'public',
                $3::text::uuid, '1787832000.000100', $4, repeat('a',64), 'U',
                'shadow', 1, clock_timestamp(), $5, clock_timestamp(), clock_timestamp())
        """,
        [
          if(identity == "derived", do: observation_id, else: Ecto.UUID.generate()),
          identity,
          ids.ingress_id,
          source_result,
          note
        ]
      )
    end

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_knowledge
        (id, scope_key, topic_key, transport, workspace_ref, conversation_ref, visibility,
         state, version, source_generation, source_dependencies, source_input_id,
         source_episode_id, latest_source_at, inserted_at, updated_at)
      VALUES ($1::text::uuid, 'reset-scope', 'retained-topic', 'slack', 'slack:T', 'slack:T:C',
              'public', $2, 1, 1, '[]', $3::text::uuid, $4::text::uuid,
              clock_timestamp(), clock_timestamp(), clock_timestamp())
      """,
      [knowledge_id, state_json, ids.ingress_id, ids.episode_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_knowledge_revisions
        (knowledge_id, version, source_generation, source_dependencies, state,
         source_input_id, source_result_ref, source_at, inserted_at)
      VALUES ($1::text::uuid, 1, 1, '[]', $2, $3::text::uuid, 'result:retained',
              clock_timestamp(), clock_timestamp())
      """,
      [knowledge_id, state_json, ids.ingress_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_knowledge_sources
        (knowledge_id, observation_id, generation, source_revision, source_fingerprint,
         source_note, retained_at, introduced_version)
      VALUES ($1::text::uuid, $2::text::uuid, 1, 1, repeat('a',64), $3, clock_timestamp(), 1)
      """,
      [knowledge_id, observation_id, note]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_knowledge_exposures
        (session_id, knowledge_id, version, turn_id, inserted_at)
      VALUES ($1::text::uuid, $2::text::uuid, 1, $3::text::uuid, clock_timestamp())
      """,
      [ids.session_id, knowledge_id, ids.turn_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_source_exposures
        (session_id, observation_id, source_input_id, receipt)
      VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, '{}')
      """,
      [ids.session_id, observation_id, ids.ingress_id]
    )
  end

  defp reset_preserved_rows(repo, prefix) do
    tables = ~w(ingress_inbox_entries episode_kernel_episodes episode_kernel_events
      episode_state_records episode_publications episode_work_sessions episode_work_turns
      episode_work_knowledge_exposures episode_work_source_exposures)

    Map.new(tables, fn table ->
      %{rows: rows} =
        SQL.query!(
          repo,
          """
          SELECT to_jsonb(row) - 'learning_run_id' - 'summary_error_code'
            - 'source_exposure_count' - 'knowledge_exposure_count' - 'completion_receipt'
            - 'selected_input_refs' - 'source_envelope' - 'engagement_receipt' AS value
          FROM #{prefix}.#{table} row ORDER BY 1
          """,
          []
        )

      {table, rows}
    end)
  end

  defp reset_derived_rows(repo, prefix) do
    Map.new(
      ~w(conversation_knowledge conversation_knowledge_revisions conversation_knowledge_sources conversation_observations),
      fn table ->
        %{rows: rows} =
          SQL.query!(
            repo,
            "SELECT to_jsonb(row) FROM #{prefix}.#{table} row ORDER BY to_jsonb(row)::text",
            []
          )

        {table, rows}
      end
    )
  end

  defp reset_topic_counts(repo, prefix) do
    SQL.query!(
      repo,
      """
      SELECT (SELECT count(*) FROM #{prefix}.conversation_knowledge),
             (SELECT count(*) FROM #{prefix}.conversation_knowledge_revisions),
             (SELECT count(*) FROM #{prefix}.conversation_knowledge_sources)
      """,
      []
    )
  end

  defp assert_reset_notes(repo, prefix, original) do
    expected =
      Map.new(original, fn [row] ->
        value =
          if row["identity_key"] == "derived",
            do: Map.merge(row, %{"note" => nil, "source_result_ref" => nil}),
            else: row

        {row["id"], value}
      end)

    %{rows: rows} =
      SQL.query!(repo, "SELECT to_jsonb(row) FROM #{prefix}.conversation_observations row", [])

    assert Map.new(rows, fn [row] -> {row["id"], row} end) == expected
  end

  defp backup_schema!(repo, prefix, temporary) do
    database = backup_database!(repo)
    backup = Path.join(temporary, "before-memory-reset.dump")
    refute File.exists?(backup)

    assert {archive, 0} =
             System.cmd(
               "docker",
               postgres_arguments("pg_dump", [
                 "--format=custom",
                 "--schema",
                 prefix,
                 "--dbname",
                 database
               ]),
               stderr_to_stdout: true
             )

    File.write!(backup, archive, [:exclusive])
    assert {listing, 0} = postgres_from_file("pg_restore", ["--list"], backup)
    assert listing =~ "SCHEMA - #{prefix}"
    %{path: backup, digest: :crypto.hash(:sha256, archive), database: database}
  end

  defp restore_schema!(repo, prefix, backup) do
    assert :crypto.hash(:sha256, File.read!(backup.path)) == backup.digest
    SQL.query!(repo, "DROP SCHEMA #{prefix} CASCADE", [])

    assert {_output, 0} =
             postgres_from_file(
               "pg_restore",
               [
                 "--exit-on-error",
                 "--no-owner",
                 "--no-privileges",
                 "--dbname",
                 backup.database
               ],
               backup.path
             )
  end

  defp backup_database!(repo) do
    # MigrationRepo is started with these runtime options, not app-env config;
    # its config/0 therefore does not expose the connection passed to start_link.
    config = Responder.Repo.config()
    database = Keyword.fetch!(config, :database)
    assert String.starts_with?(database, "responder_test")

    identity_query =
      "SELECT current_database() || ':' || system_identifier FROM pg_control_system()"

    assert %{rows: [[identity]]} = SQL.query!(repo, identity_query, [])

    assert {container_identity, 0} =
             System.cmd(
               "docker",
               postgres_arguments("psql", [
                 "-At",
                 "--dbname",
                 database,
                 "--command",
                 identity_query
               ]),
               stderr_to_stdout: true
             )

    assert String.trim(container_identity) == identity
    database
  end

  defp postgres_arguments(command, arguments) do
    # Reuse the gate's pinned server clients; a host pg_dump may be older than
    # PostgreSQL 18 even when every existing development prerequisite is present.
    [
      "compose",
      "--project-name",
      "responder-kernel",
      "--file",
      Path.expand("../../../compose.test.yml", __DIR__),
      "exec",
      "-T",
      "--user",
      "postgres",
      "episode-db",
      command
      | arguments
    ]
  end

  defp postgres_from_file(command, arguments, path) do
    # Fixed shell code supplies stdin only; all commands and paths remain
    # separate arguments, including temporary paths containing spaces.
    System.cmd(
      "sh",
      [
        "-c",
        "exec \"$@\" < \"$RESPONDER_MIGRATION_BACKUP\"",
        "memory-reset-backup",
        "docker" | postgres_arguments(command, arguments)
      ],
      env: [{"RESPONDER_MIGRATION_BACKUP", path}],
      stderr_to_stdout: true
    )
  end

  defp insert_wait_migration_rows!(repo, prefix, ids) do
    record_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_state_records (
        id, episode_id, turn_id, ref, operation_id, kind, status, payload,
        payload_fingerprint, sequence, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid,
        'record:event-wait:timer-migration', 'wait-migration', 'event_wait', 'open',
        '{"deadline_at":"2099-01-01T01:00:00Z","event_matcher":{},"kind":"source_event","verification":"verify"}',
        repeat('d', 64), 1, clock_timestamp(), clock_timestamp()
      )
      """,
      [record_id, ids.episode_id, ids.turn_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_event_subscriptions (
        id, episode_id, record_id, ref, status, source_kind, matcher, cursor,
        poll_after, deadline_at, revision, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid,
        'event-subscription:timer-migration', 'active', 'github', '{"state":"healthy"}',
        '{"revision":"abc123"}', '2099-01-01T00:30:00Z', '2099-01-01T01:00:00Z',
        1, clock_timestamp(), clock_timestamp()
      )
      """,
      [Ecto.UUID.generate(), ids.episode_id, record_id]
    )
  end

  defp rollback_card_lab_feedback!(repo, prefix) do
    rollback_workspace!(repo, prefix)

    assert Ecto.Migrator.run(repo, @migrations_path, :down,
             step: 1,
             prefix: prefix,
             log: false
           ) == [@card_lab_feedback_version]

    refute table_exists?(repo, prefix, "card_lab_feedback")
  end

  defp rollback_workspace!(repo, prefix) do
    assert Ecto.Migrator.run(repo, @migrations_path, :down,
             to_exclusive: @card_lab_feedback_version,
             prefix: prefix,
             log: false
           ) == Enum.reverse(@workspace_versions)
  end

  defp start_migration_repo! do
    config =
      Responder.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end

  defp migration_temporary_directory! do
    # ExUnit's tmp_dir tag defaults to the checkout. Dumps and copied migrations
    # must neither dirty the worktree nor become accidental release inputs.
    directory = Path.join(System.tmp_dir!(), "responder-migration-#{Ecto.UUID.generate()}")
    repository = Path.expand("../../..", @migrations_path)
    refute String.starts_with?(Path.expand(directory), repository <> "/")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    File.chmod!(directory, 0o700)
    directory
  end

  defp historical_migrations!(temporary) do
    path = Path.join(temporary, "reversible-release-migrations")
    File.mkdir!(path)

    for source <- Path.wildcard(Path.join(@migrations_path, "*.exs")),
        {version, _name} = Integer.parse(Path.basename(source)),
        version <= @candidate_responses_version do
      target = Path.join(path, Path.basename(source))
      File.cp!(source, target)
      assert File.read!(target) == File.read!(source)
    end

    path
  end

  defp table_exists?(repo, prefix, table) do
    %{rows: [[exists?]]} =
      SQL.query!(
        repo,
        "SELECT to_regclass($1) IS NOT NULL",
        [prefix <> "." <> table]
      )

    exists?
  end

  defp column_nullable?(repo, prefix, table, column) do
    %{rows: [[nullable?]]} =
      SQL.query!(
        repo,
        """
        SELECT is_nullable = 'YES'
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [prefix, table, column]
      )

    nullable?
  end

  defp insert_global_fact!(repo, prefix) do
    id = Ecto.UUID.generate()

    # Structural rollback fixture: the shape of an answer-confirmed fact, not a saved answer.
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.operational_memory_entries (
        id, ref, kind, status, workspace_ref, scope_kind, scope_ref, visibility, subject,
        payload, payload_fingerprint, confirmed_by_actor_ref, confirmation_ref, confirmed_at,
        source_transport, source_conversation_ref, source_message_ref, expires_at,
        answer_provenance, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'memory:rollback-proof', 'entity_relationship', 'active',
        'installation', 'global', 'installation:' || repeat('a', 64), 'global', 'GCP project',
        '{"applicability":"Production portal","value":"portal-prod"}', repeat('b', 64),
        'slack:user:U123', 'answer:rollback-proof', clock_timestamp(), 'slack',
        'slack:T123:C123', '1787832000.000100', NULL,
        '{"answer_ref":"answer:rollback-proof","question_ref":"record:input_request:rollback"}',
        clock_timestamp(), clock_timestamp()
      )
      """,
      [id]
    )

    id
  end

  defp insert_default_channel_configuration!(repo, prefix) do
    id = Ecto.UUID.generate()

    # Structural rollback fixture: the shape of a configuration nobody clicked for.
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.slack_channel_configurations (
        id, workspace_ref, channel_ref, participation, repository_ref, alert_policy,
        invite_user_refs, invite_user_group_refs, actor_ref, revision, saved_at,
        welcome_message_ref, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'T123', 'C-rollback', 'mentions', 'responder', 'reply',
        ARRAY[]::text[], ARRAY[]::text[], NULL, 1, clock_timestamp(),
        '1787832000.000100', clock_timestamp(), clock_timestamp()
      )
      """,
      [id]
    )

    id
  end

  defp insert_typed_answer!(repo, prefix, record_id, inbox_entry_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_state_record_responses (
        id, record_id, inbox_entry_id, response_ref, actor_ref, choice_index, choice,
        occurred_at, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid, 'answer:typed-rollback', 'U123',
        NULL, NULL, clock_timestamp(), clock_timestamp(), clock_timestamp()
      )
      """,
      [id, record_id, inbox_entry_id]
    )

    id
  end

  defp column_exists?(repo, prefix, table, column) do
    %{rows: [[exists?]]} =
      SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        )
        """,
        [prefix, table, column]
      )

    exists?
  end

  defp constraint_definition(repo, prefix, table, constraint) do
    %{rows: [[definition]]} =
      SQL.query!(
        repo,
        """
        SELECT pg_get_constraintdef(c.oid)
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = $1 AND t.relname = $2 AND c.conname = $3
        """,
        [prefix, table, constraint]
      )

    definition
  end

  defp cascading_foreign_key?(repo, prefix, constraint) do
    %{rows: [[cascades?]]} =
      SQL.query!(
        repo,
        """
        SELECT foreign_key.confdeltype = 'c'
        FROM pg_constraint AS foreign_key
        JOIN pg_namespace AS namespace ON namespace.oid = foreign_key.connamespace
        WHERE namespace.nspname = $1 AND foreign_key.conname = $2
        """,
        [prefix, constraint]
      )

    cascades?
  end

  defp insert_stage3_rows!(repo, prefix) do
    episode_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    turn_id = Ecto.UUID.generate()
    ingress_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_kernel_episodes (
        id, key, state, owner_kind, owner_ref,
        destination_transport, destination_conversation_ref, destination_thread_ref,
        semantic_version, next_sequence, input_revisions, active_input_refs,
        queued_input_refs, queued_input_order_keys, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'episode:stage3', 'working', 'turn', 'turn:stage3',
        'slack', 'workspace:C123', '1710000000.000100',
        0, 1, '{}', '{}', '{}', '{}', clock_timestamp(), clock_timestamp()
      )
      """,
      [episode_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_sessions (
        id, episode_id, policy, policy_digest, external_ref,
        generation, create_generation, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, $2::text::uuid, 'engineering-read-only', repeat('a', 64),
        'episode:stage3:session:1', 1, 1, clock_timestamp(), clock_timestamp()
      )
      """,
      [session_id, episode_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_turns (
        id, episode_id, turn_ref, session_id, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, $2::text::uuid, 'turn:stage3', $3::text::uuid,
        clock_timestamp(), clock_timestamp()
      )
      """,
      [turn_id, episode_id, session_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.ingress_inbox_entries (
        id, dedupe_key, event_fingerprint, source_kind, source_ref, source_item_ref,
        event_ref, event_kind, native_input_id, actor_kind, actor_ref, can_react,
        destination_transport, destination_conversation_ref, destination_thread_ref,
        revision, occurred_at, content, status, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'dedupe:stage3', repeat('b', 64), 'slack', 'workspace',
        '1710000000.000100', 'event:stage3', 'message', 'message:stage3', 'user',
        'U123', true, 'slack', 'workspace:C123', '1710000000.000100', 1,
        clock_timestamp(), '{"text":"keep me"}', 'pending',
        clock_timestamp(), clock_timestamp()
      )
      """,
      [ingress_id]
    )

    %{episode_id: episode_id, session_id: session_id, turn_id: turn_id, ingress_id: ingress_id}
  end

  defp assert_upgraded_rows!(repo, prefix, ids) do
    assert %{rows: [["live", nil]]} =
             SQL.query!(
               repo,
               "SELECT execution_mode, history_pruned_at FROM #{prefix}.episode_kernel_episodes WHERE id = $1::text::uuid",
               [ids.episode_id]
             )

    assert %{rows: [["active", nil, nil]]} =
             SQL.query!(
               repo,
               "SELECT cleanup_status, repository_ref, workspace_task FROM #{prefix}.episode_work_sessions WHERE id = $1::text::uuid",
               [ids.session_id]
             )

    assert %{rows: [[0, false, false]]} =
             SQL.query!(
               repo,
               "SELECT delivery_retry_generation, usage_recorded, timing_recorded FROM #{prefix}.episode_work_turns WHERE id = $1::text::uuid",
               [ids.turn_id]
             )

    assert %{rows: [[~s({"react":{"emoji_names":null}}), "live", nil]]} =
             SQL.query!(
               repo,
               "SELECT source_capabilities, execution_mode, work_policy FROM #{prefix}.ingress_inbox_entries WHERE id = $1::text::uuid",
               [ids.ingress_id]
             )
  end

  defp assert_authority_fields!(repo, prefix, ids) do
    assert %{rows: [[nil]]} =
             SQL.query!(
               repo,
               "SELECT authority_digest FROM #{prefix}.episode_work_sessions WHERE id = $1::text::uuid",
               [ids.session_id]
             )

    assert column_exists?(repo, prefix, "coop_workers", "policy_authority_digests")
  end

  defp insert_admission_session!(repo, prefix) do
    session_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_sessions (
        id, episode_id, execution_kind, policy, policy_digest, external_ref,
        generation, create_generation, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, NULL, 'admission', 'admission-read-only', repeat('a', 64),
        'responder-admission:migration-round-trip:g1', 1, 1,
        clock_timestamp(), clock_timestamp()
      )
      """,
      [session_id]
    )

    session_id
  end

  defp insert_stale_head_recovery_rows!(repo, prefix, ids) do
    record_id = Ecto.UUID.generate()
    publication_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_state_records (
        id, episode_id, turn_id, ref, operation_id, kind, status, payload,
        payload_fingerprint, sequence, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, $2::text::uuid, $3::text::uuid,
        'record:publication:rollback', 'host:publication:ready', 'publication_offer',
        'open', '{"title":"Rollback proof"}', repeat('c', 64), 1,
        clock_timestamp(), clock_timestamp()
      )
      """,
      [record_id, ids.episode_id, ids.turn_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_publications (
        id, ref, episode_id, record_id, session_id, repository, title, body, status,
        destination_transport, destination_conversation_ref, destination_thread_ref,
        offer_message_ref, review_request_ref, review_requested_by_actor_ref,
        review_requested_at, review_generation, recovery_generation, attempt_count,
        github_repository, branch_ref, commit_sha, expected_remote_head_sha,
        pull_request_number, pull_request_url, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'publication:rollback-proof', $2::text::uuid, $3::text::uuid,
        $4::text::uuid, 'responder', 'Rollback proof', 'Preserve the observed head.',
        'review_pending', 'slack', 'slack:T123:C123', 'thread:rollback',
        'message:offer', 'interaction:review', 'slack:user:U123', clock_timestamp(),
        1, 1, 0, 'acme/responder', 'refs/heads/responder/rollback-proof', repeat('d', 40),
        repeat('e', 40), 42, 'https://github.com/acme/responder/pull/42',
        clock_timestamp(), clock_timestamp()
      )
      """,
      [publication_id, ids.episode_id, record_id, ids.session_id]
    )

    {record_id, publication_id}
  end

  defp insert_publication_recovery_action!(repo, prefix) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.responder_operator_actions (
        id, action_ref, request_fingerprint, actor_ref, action, kind, resource_ref,
        previous, outcome, occurred_at, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'operator-action:rollback-proof', repeat('f', 64),
        'control-plane:operator', 'update', 'publication', 'publication:rollback-proof',
        '{}', '{}', clock_timestamp(), clock_timestamp(), clock_timestamp()
      )
      """,
      [Ecto.UUID.generate()]
    )
  end

  defp assert_stage3_rows!(repo, prefix, ids) do
    assert %{rows: [["working"]]} =
             SQL.query!(
               repo,
               "SELECT state FROM #{prefix}.episode_kernel_episodes WHERE id = $1::text::uuid",
               [ids.episode_id]
             )

    assert %{rows: [["engineering-read-only"]]} =
             SQL.query!(
               repo,
               "SELECT policy FROM #{prefix}.episode_work_sessions WHERE id = $1::text::uuid",
               [ids.session_id]
             )

    assert %{rows: [["turn:stage3"]]} =
             SQL.query!(
               repo,
               "SELECT turn_ref FROM #{prefix}.episode_work_turns WHERE id = $1::text::uuid",
               [ids.turn_id]
             )

    assert %{rows: [[true, ~s({"text":"keep me"})]]} =
             SQL.query!(
               repo,
               "SELECT can_react, content FROM #{prefix}.ingress_inbox_entries WHERE id = $1::text::uuid",
               [ids.ingress_id]
             )
  end
end
