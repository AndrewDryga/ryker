defmodule Ryker.Memories.CaseConversationsMigrationTest do
  @moduledoc """
  Deleting a Slack channel withdraws every case built from its messages
  (2026-09-28), and work can gather messages from more than one conversation,
  so a case records every conversation its messages came from. A case kept
  before that learns the conversations of the messages Ryker still holds, by
  the message identities it keeps; rolling back forgets only the
  conversations.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @previous_version 20_260_928_140_000
  @version 20_260_928_160_000
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)

  test "a case kept before learns the conversations of the messages still held, found by an index" do
    repo = start_migration_repo!()
    prefix = "case_conversations_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      migrate!(repo, prefix, @previous_version)

      # Work in #ops that a message from #pages joined; the message from
      # #ops itself has already expired.
      message!(repo, prefix, "slack-message:paged", "slack:T123:CPAGES")
      joined = case!(repo, prefix, ["slack-message:expired", "slack-message:paged"])
      alone = case!(repo, prefix, ["slack-message:gone"])

      assert @version in migrate!(repo, prefix, @version)

      assert conversations(repo, prefix, joined) == ["slack:T123:CPAGES"]
      assert conversations(repo, prefix, alone) == []

      # The lookup a channel's deletion makes.
      assert {:ok, plan} =
               repo.transaction(fn ->
                 SQL.query!(repo, "SET LOCAL enable_seqscan = off", [])

                 SQL.query!(
                   repo,
                   """
                   EXPLAIN SELECT id FROM #{prefix}.episode_case_records
                   WHERE conversation_refs @> ARRAY[$1]::text[]
                   """,
                   ["slack:T123:CPAGES"]
                 ).rows
                 |> List.flatten()
                 |> Enum.join("\n")
               end)

      assert plan =~ "episode_case_records_conversation_refs_index"

      assert_raise Postgrex.Error, ~r/episode_case_record_conversations_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.episode_case_records SET conversation_refs = $2 WHERE id = $1",
          [Ecto.UUID.dump!(alone), Enum.map(1..65, &"slack:T123:C#{&1}")]
        )
      end

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@version]

      %{rows: [[kept]]} =
        SQL.query!(repo, "SELECT count(*) FROM #{prefix}.episode_case_records", [])

      assert kept == 2
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp conversations(repo, prefix, id) do
    %{rows: [[conversations]]} =
      SQL.query!(
        repo,
        "SELECT conversation_refs FROM #{prefix}.episode_case_records WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    conversations
  end

  defp message!(repo, prefix, native_input_id, conversation_ref) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.ingress_inbox_entries (
        id, dedupe_key, event_fingerprint, source_kind, source_ref, event_ref, event_kind,
        native_input_id, source_item_ref, actor_kind, actor_ref, destination_transport,
        destination_conversation_ref, revision, occurred_at, content, status, inserted_at,
        updated_at, source_capabilities
      ) VALUES (
        $1, $2, $3, 'slack', 'T123', $2, 'message', $4, '1787832000.000300', 'user', 'U123',
        'slack', $5, 1, now(), '{}', 'pending', now(), now(), '{}'
      )
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        "dedupe:#{native_input_id}",
        String.duplicate("a", 64),
        native_input_id,
        conversation_ref
      ]
    )
  end

  defp case!(repo, prefix, source_refs) do
    id = Ecto.UUID.generate()
    episode_id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_case_records (
        id, case_ref, episode_id, episode_key, execution_mode, transport, conversation_ref,
        workspace_ref, problem, search_text, source_refs, status, closed_at,
        content_fingerprint, inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, $4, 'live', 'slack', 'slack:T123:COPS', 'slack:T123',
        'Postgres primary is unreachable', 'Postgres primary is unreachable', $5, 'active',
        now(), $6, now(), now()
      )
      """,
      [
        Ecto.UUID.dump!(id),
        "case:#{episode_id}",
        Ecto.UUID.dump!(episode_id),
        "work:#{episode_id}",
        source_refs,
        String.duplicate("b", 64)
      ]
    )

    id
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
