defmodule Responder.Ingress.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Responder.Release

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
               @publication_stale_head_version
             ]

      refute table_exists?(repo, prefix, "slack_inbox_entries")
      assert table_exists?(repo, prefix, "ingress_inbox_entries")
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

      assert cascading_foreign_key?(
               repo,
               prefix,
               "coop_worker_workspace_checkpoint_command_worker_fkey"
             )
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "populated Stage 3 custody survives product upgrade, rollback, and re-upgrade" do
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
               all: true,
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
               @publication_stale_head_version
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
               all: true,
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
               @publication_stale_head_version
             ]

      assert_upgraded_rows!(repo, prefix, ids)
      assert_authority_fields!(repo, prefix, ids)
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  test "the release migrator upgrades once and rolls back only the expected latest version" do
    repo = start_migration_repo!()
    prefix = "release_migrator_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    options = [repo: repo, prefix: prefix, migrations_path: @migrations_path, log: false]

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
               @publication_stale_head_version
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
        all: true,
        prefix: prefix,
        log: false
      )

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

  defp start_migration_repo! do
    config =
      Responder.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
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
