defmodule Ryker.LocalRouting.MigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @previous_version 20_260_927_190_000
  @version 20_260_927_191_000
  @digest String.duplicate("a", 64)

  # The local routing model arrives on installations that already chose their
  # models and routed their messages: it must arrive off and leave every saved
  # choice as it was. Rolling back must not drop what someone typed into it or
  # the comparisons it measured, since the previous release has nowhere to
  # keep either.
  test "the local routing model arrives off, keeps saved models, and a rollback keeps what it holds" do
    repo = start_migration_repo!()
    prefix = "local_routing_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      migrate!(repo, prefix, @previous_version)

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.installation_settings (host_ref, revision, saved_by, saved_at, inserted_at)
        VALUES ('host-local', 1, 'operator:test', now(), now())
        """,
        []
      )

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.work_settings (id, workspace_ref, routing_models)
        VALUES ('host-local', 'workers', ARRAY['codex:gpt-5.6-luna/low@default'])
        """,
        []
      )

      input_id = insert_input!(repo, prefix)

      assert @version in migrate!(repo, prefix, @version)

      assert %{rows: [["workers", ["codex:gpt-5.6-luna/low@default"], "off", nil, nil]]} =
               SQL.query!(
                 repo,
                 """
                 SELECT workspace_ref, routing_models, local_routing_mode, local_routing_endpoint,
                        local_routing_model
                 FROM #{prefix}.work_settings
                 """,
                 []
               )

      assert_raise Postgrex.Error, ~r/work_settings_local_routing_valid/, fn ->
        SQL.query!(repo, "UPDATE #{prefix}.work_settings SET local_routing_mode = 'shadow'", [])
      end

      SQL.query!(
        repo,
        """
        UPDATE #{prefix}.work_settings
        SET local_routing_mode = 'shadow',
            local_routing_endpoint = 'http://host.docker.internal:11434/v1',
            local_routing_model = 'qwen2.5:3b'
        """,
        []
      )

      insert_comparison!(repo, prefix, input_id)

      # One comparison per routing decision.
      assert_raise Postgrex.Error, ~r/local_routing_comparisons_input_id_generation_index/, fn ->
        insert_comparison!(repo, prefix, input_id)
      end

      assert_raise Postgrex.Error, ~r/local routing comparisons are recorded/, fn ->
        rollback!(repo, prefix)
      end

      SQL.query!(repo, "DELETE FROM #{prefix}.local_routing_comparisons", [])

      assert_raise Postgrex.Error, ~r/Local routing model is set/, fn ->
        rollback!(repo, prefix)
      end

      SQL.query!(
        repo,
        """
        UPDATE #{prefix}.work_settings
        SET local_routing_mode = 'off', local_routing_endpoint = NULL, local_routing_model = NULL
        """,
        []
      )

      assert rollback!(repo, prefix) == [@version]
      refute table_exists?(repo, prefix, "local_routing_comparisons")

      assert %{rows: [["workers", ["codex:gpt-5.6-luna/low@default"]]]} =
               SQL.query!(
                 repo,
                 "SELECT workspace_ref, routing_models FROM #{prefix}.work_settings",
                 []
               )

      assert @version in migrate!(repo, prefix, @version)
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp migrate!(repo, prefix, version),
    do:
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
        to: version,
        prefix: prefix,
        log: false
      )

  defp rollback!(repo, prefix),
    do:
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
        step: 1,
        prefix: prefix,
        log: false
      )

  defp insert_input!(repo, prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.ingress_inbox_entries (
        id, dedupe_key, event_fingerprint, source_kind, source_ref, event_ref, event_kind,
        native_input_id, actor_kind, actor_ref, destination_transport,
        destination_conversation_ref, revision, occurred_at, content, status, inserted_at,
        updated_at, source_capabilities
      ) VALUES (
        $1::text::uuid, 'dedupe:local', $2, 'slack', 'T123', 'Ev-local', 'message',
        'native-local', 'user', 'U123', 'slack', 'slack:T123:C456', 1, now(), '{}', 'pending',
        now(), now(), '{}'
      )
      """,
      [id, @digest]
    )

    id
  end

  defp insert_comparison!(repo, prefix, input_id) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.local_routing_comparisons (
        id, input_id, generation, execution_mode, status, local_model, inserted_at, updated_at
      ) VALUES (gen_random_uuid(), $1::text::uuid, 1, 'live', 'pending', 'qwen2.5:3b', now(), now())
      """,
      [input_id]
    )
  end

  defp table_exists?(repo, prefix, table) do
    %{rows: [[exists?]]} =
      SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2
        )
        """,
        [prefix, table]
      )

    exists?
  end

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
