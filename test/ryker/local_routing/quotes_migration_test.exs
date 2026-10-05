defmodule Ryker.LocalRouting.QuotesMigrationTest do
  @moduledoc """
  A local routing comparison records what its prompt quotes, as a routing
  example does, so a person forgetting a message finds every comparison of a
  prompt that quoted it by an index instead of reading each one's context
  (2026-09-28). The comparisons kept before must come through with the very
  keys routing records now, or forgetting would miss exactly those. Rolling
  back keeps every comparison and only forgets the keys.
  """
  use Ryker.MigrationCase

  alias Ecto.Adapters.SQL
  alias Ryker.CanonicalJSON
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.Observations
  alias Ryker.RoutingExamples

  @previous_version 20_260_927_220_000
  @version 20_260_928_100_000
  @topic "0c7c2f2e-5b1d-4d5e-9d44-3c1b58f6a0d1"

  # What a routing prompt quotes, as routing froze it: the thread it was in,
  # a note learned in another channel, and a learned topic from a third.
  @context %{
    "conversation_context" => %{
      "root" => %{"source_message_ref" => "1787832000.000100", "text" => "deploy is stuck"},
      "current" => %{"source_message_ref" => "1787832000.000300", "text" => "any news?"},
      "messages" => [%{"source_message_ref" => "1787832000.000200", "text" => "looking"}]
    },
    "conversation_observations" => [
      %{"conversation_ref" => "slack:T123:C900", "source_message_ref" => "1787831000.000100"}
    ],
    "conversation_knowledge" => [
      %{"source_ref" => "knowledge:#{@topic}", "conversation_ref" => "slack:T123:C901"}
    ]
  }

  test "a comparison kept before its quotes were recorded gets the keys forgetting finds it by" do
    in_scratch_schema("local_routing_quotes", fn repo, prefix ->
      migrate!(repo, prefix, @previous_version)
      input_id = insert_input!(repo, prefix)
      comparison_id = insert_comparison!(repo, prefix, input_id)

      assert @version in migrate!(repo, prefix, @version)

      entry = %Entry{
        source_kind: "slack",
        source_ref: "T123",
        native_input_id: "slack-message:local",
        source_item_ref: "1787832000.000300",
        destination_conversation_ref: "slack:T123:C456",
        admission_context: @context
      }

      quoted = RoutingExamples.quoted_keys(entry)

      assert quotes(repo, prefix, comparison_id) ==
               [Observations.source_identity(entry), quoted.keys, quoted.conversations]

      # Every quote the prompt holds is among them: the message, its thread,
      # the note from another channel and the topic.
      assert length(quoted.keys) == 5

      assert quoted.conversations == ["slack:T123:C456", "slack:T123:C900", "slack:T123:C901"]

      # A comparison that does not name its message is refused.
      assert_raise Postgrex.Error, ~r/local_routing_comparison_quotes_valid/, fn ->
        insert_comparison!(repo, prefix, input_id, generation: 2, source_identity: "unknown")
      end

      assert rollback!(repo, prefix) == [@version]
      assert count(repo, prefix) == 1
      assert @version in migrate!(repo, prefix, @version)
    end)
  end

  defp quotes(repo, prefix, id) do
    %{rows: [row]} =
      SQL.query!(
        repo,
        """
        SELECT source_identity, message_keys, conversation_refs
        FROM #{prefix}.local_routing_comparisons WHERE id = $1::text::uuid
        """,
        [id]
      )

    row
  end

  defp count(repo, prefix) do
    %{rows: [[count]]} =
      SQL.query!(repo, "SELECT count(*) FROM #{prefix}.local_routing_comparisons", [])

    count
  end

  defp insert_input!(repo, prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.ingress_inbox_entries (
        id, dedupe_key, event_fingerprint, source_kind, source_ref, event_ref, event_kind,
        native_input_id, source_item_ref, actor_kind, actor_ref, destination_transport,
        destination_conversation_ref, revision, occurred_at, content, status, inserted_at,
        updated_at, source_capabilities, admission_context, admission_context_fingerprint
      ) VALUES (
        $1::text::uuid, 'dedupe:local', $2, 'slack', 'T123', 'Ev-local', 'message',
        'slack-message:local', '1787832000.000300', 'user', 'U123', 'slack', 'slack:T123:C456',
        1, now(), '{}', 'pending', now(), now(), '{}', $3, $2
      )
      """,
      [id, String.duplicate("a", 64), CanonicalJSON.encode!(@context)]
    )

    id
  end

  # One the local model already answered, with the answer it gave.
  defp insert_comparison!(repo, prefix, input_id, options \\ []) do
    id = Ecto.UUID.generate()
    {columns, values} = identity(options)

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.local_routing_comparisons (
        id, input_id, generation, execution_mode, status, local_model, valid, agrees,
        local_answer, local_ms, compared_at, inserted_at, updated_at#{columns}
      ) VALUES (
        $1::text::uuid, $2::text::uuid, $3, 'live', 'compared', 'qwen2.5:3b', true, true,
        '{"action":"quick_reply"}', 900, now(), now(), now()#{values}
      )
      """,
      [id, input_id, Keyword.get(options, :generation, 1)]
    )

    id
  end

  defp identity(options) do
    case Keyword.fetch(options, :source_identity) do
      {:ok, identity} -> {", source_identity", ", '#{identity}'"}
      :error -> {"", ""}
    end
  end
end
