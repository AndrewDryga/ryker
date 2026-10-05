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
  use Ryker.MigrationCase

  alias Ecto.Adapters.SQL

  @version 20_260_926_200_000
  @digest String.duplicate("a", 64)

  test "no table announces its writes through a trigger once the schema is migrated" do
    assert triggered_tables(Repo, "public") == []
    refute notify_function?(Repo, "public")
  end

  test "dropping the triggers keeps every row, and rolling back puts them back" do
    in_scratch_schema("notify_triggers", fn repo, prefix ->
      migrate!(repo, prefix, Ryker.TestMigrations.version_before(@version))

      triggered = triggered_tables(repo, prefix)
      assert "ingress_inbox_entries" in triggered
      assert "episode_work_turns" in triggered
      assert notify_function?(repo, prefix)
      input_id = insert_input!(repo, prefix)

      assert migrate!(repo, prefix, @version) == [@version]

      assert triggered_tables(repo, prefix) == []
      refute notify_function?(repo, prefix)
      assert input_ids(repo, prefix) == [input_id]

      assert rollback!(repo, prefix) == [@version]

      assert triggered_tables(repo, prefix) == triggered
      assert notify_function?(repo, prefix)
      assert input_ids(repo, prefix) == [input_id]
    end)
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
end
