defmodule Ryker.Memories.CaseConversationsMigrationTest do
  @moduledoc """
  Deleting a Slack channel withdraws every case built from its messages
  (2026-09-28), and work can gather messages from more than one conversation,
  so a case records every conversation its messages came from. A case kept
  before that learns the conversations of the messages Ryker still holds, by
  the message identities it keeps; rolling back forgets only the
  conversations.
  """
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @previous_version 20_260_928_140_000
  @version 20_260_928_160_000

  test "a case kept before learns the conversations of the messages still held, found by an index" do
    in_scratch_schema("case_conversations", fn repo, prefix ->
      migrate!(repo, prefix, @previous_version)

      # Work in #ops that a message from #pages joined; the message from
      # #ops itself has already expired.
      message!(repo, prefix, "slack-message:paged", "slack:T123:CPAGES")
      joined = case!(repo, prefix, ["slack-message:expired", "slack-message:paged"])
      alone = case!(repo, prefix, ["slack-message:gone"])

      assert @version in migrate!(repo, prefix, @version)

      assert conversations(repo, prefix, joined) == ["slack:T123:CPAGES"]
      assert conversations(repo, prefix, alone) == []

      # The lookup a channel's deletion makes, `conversation_refs @> ARRAY[...]`, has a GIN index.
      # Whether the planner may use it yet depends on every other transaction on the server: the
      # migration fills the column and builds the index in one transaction, so Postgres holds the
      # index back (pg_index.indcheckxmin) until each older transaction has ended. Asking the
      # planner failed every gate run on 2026-10-04, when other partitions always had one open.
      %{rows: [[definition, valid]]} =
        SQL.query!(
          repo,
          """
          SELECT pg_get_indexdef(index.indexrelid), index.indisvalid
          FROM pg_index AS index
          JOIN pg_class AS class ON class.oid = index.indexrelid
          JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
          WHERE namespace.nspname = $1
            AND class.relname = 'episode_case_records_conversation_refs_index'
          """,
          [prefix]
        )

      assert valid
      assert definition =~ "USING gin (conversation_refs)"

      assert_raise Postgrex.Error, ~r/episode_case_record_conversations_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.episode_case_records SET conversation_refs = $2 WHERE id = $1",
          [Ecto.UUID.dump!(alone), Enum.map(1..65, &"slack:T123:C#{&1}")]
        )
      end

      assert rollback!(repo, prefix) ==
               [@version]

      %{rows: [[kept]]} =
        SQL.query!(repo, "SELECT count(*) FROM #{prefix}.episode_case_records", [])

      assert kept == 2
    end)
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
end
