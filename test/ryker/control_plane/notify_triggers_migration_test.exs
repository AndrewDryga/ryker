defmodule Ryker.ControlPlane.NotifyTriggersMigrationTest do
  @moduledoc """
  Open pages hear about changes from the contexts that make them
  (`Ryker.PubSub`). Until 2026-09-26 a statement trigger on 93 tables sent
  each table's name to a listener that guessed which pages might care, so
  every write in the installation paid for a NOTIFY, and a page learned only
  that a table had changed, never what. The migration that removes the
  triggers must leave no table announcing its writes that way, keep every row,
  and put the triggers back on the way down for a release that listens again.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @version 20_260_926_200_000
  @digest String.duplicate("a", 64)

  test "no table announces its writes through a trigger once the schema is migrated" do
    repo = start_migration_repo!()

    assert triggered_tables(repo, "public") == []
    refute notify_function?(repo, "public")
  end

  test "dropping the triggers keeps every row, and rolling back puts them back" do
    repo = start_migration_repo!()
    prefix = "notify_triggers_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
        to: version_before(@version),
        prefix: prefix,
        log: false
      )

      triggered = triggered_tables(repo, prefix)
      assert "ingress_inbox_entries" in triggered
      assert "episode_work_turns" in triggered
      assert notify_function?(repo, prefix)
      input_id = insert_input!(repo, prefix)

      assert Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
               to: @version,
               prefix: prefix,
               log: false
             ) == [@version]

      assert triggered_tables(repo, prefix) == []
      refute notify_function?(repo, prefix)
      assert input_ids(repo, prefix) == [input_id]

      assert Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
               step: 1,
               prefix: prefix,
               log: false
             ) ==
               [@version]

      assert triggered_tables(repo, prefix) == triggered
      assert notify_function?(repo, prefix)
      assert input_ids(repo, prefix) == [input_id]
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp triggered_tables(repo, schema) do
    %{rows: rows} =
      SQL.query!(
        repo,
        """
        SELECT DISTINCT event_object_table FROM information_schema.triggers
        WHERE trigger_name = 'ryker_control_plane_changed' AND event_object_schema = $1
        ORDER BY event_object_table
        """,
        [schema]
      )

    List.flatten(rows)
  end

  defp notify_function?(repo, schema) do
    %{rows: [[exists?]]} =
      SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_proc AS function
          JOIN pg_namespace AS namespace ON namespace.oid = function.pronamespace
          WHERE function.proname = 'ryker_control_plane_notify' AND namespace.nspname = $1
        )
        """,
        [schema]
      )

    exists?
  end

  defp input_ids(repo, prefix) do
    %{rows: rows} =
      SQL.query!(repo, "SELECT id::text FROM #{prefix}.ingress_inbox_entries", [])

    List.flatten(rows)
  end

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
        $1::text::uuid, 'dedupe:notify', $2, 'slack', 'T123', 'Ev-notify', 'message',
        'native-notify', 'user', 'U123', 'slack', 'slack:T123:C456', 1, now(), '{}', 'pending',
        now(), now(), '{}'
      )
      """,
      [id, @digest]
    )

    id
  end

  # The newest migration before this one, whatever the others are named, so
  # the rollback is compared with the schema this migration found.
  defp version_before(version), do: Ryker.TestMigrations.version_before(version)

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
