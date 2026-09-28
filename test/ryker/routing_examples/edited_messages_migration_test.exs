defmodule Ryker.RoutingExamples.EditedMessagesMigrationTest do
  @moduledoc """
  An edit takes back the words it replaced (2026-09-28), so every copy of a
  routing decision checks each message it quotes for an edit before it is
  kept, as it checks for a deletion. Without an index of its own that check
  reads every message of the conversation, once per copy.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @previous_version 20_260_928_100_000
  @version 20_260_928_140_000
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)

  test "the edits of the messages a prompt quotes are found by an index, and rolling back drops only it" do
    repo = start_migration_repo!()
    prefix = "edited_messages_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      migrate!(repo, prefix, @previous_version)
      refute index?(repo, prefix)

      assert @version in migrate!(repo, prefix, @version)
      assert index?(repo, prefix)

      # The lookup `Ryker.RoutingExamples` makes, by conversation and message.
      plan =
        repo.transaction(fn ->
          SQL.query!(repo, "SET LOCAL enable_seqscan = off", [])

          SQL.query!(
            repo,
            """
            EXPLAIN SELECT id FROM #{prefix}.ingress_inbox_entries
            WHERE event_kind = 'edit' AND destination_conversation_ref = ANY($1)
              AND COALESCE(source_item_ref, native_input_id) = ANY($2)
            """,
            [["slack:T123:C456"], ["1787832000.000100"]]
          ).rows
          |> List.flatten()
          |> Enum.join("\n")
        end)

      assert {:ok, plan} = plan
      assert plan =~ "ingress_inbox_edited_messages"

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@version]

      refute index?(repo, prefix)
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp index?(repo, prefix) do
    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = 'ingress_inbox_edited_messages'",
        [prefix]
      )

    rows != []
  end

  defp migrate!(repo, prefix, version),
    do: Ecto.Migrator.run(repo, @migrations_path, :up, to: version, prefix: prefix, log: false)

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
