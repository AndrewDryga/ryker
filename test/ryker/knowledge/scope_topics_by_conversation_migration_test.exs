defmodule Ryker.Knowledge.ScopeTopicsByConversationMigrationTest do
  @moduledoc """
  V10, 2026-09-28: #test's "Emisar MCP access" topic, keyed by the channel's
  conversation and its repository at the time, was never offered to a later
  pass once the channel's work moved to another repository. The migration
  re-keys every topic by its conversation, keeps every topic when two of one
  conversation shared a key, and rolls back to the repository keys.
  """
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.CanonicalJSON
  alias Ryker.Knowledge.KnowledgeAnchors

  @previous_version 20_260_929_000_000
  @version 20_260_929_010_000
  @conversation %{
    "conversation_ref" => "slack:T1:C1",
    "transport" => "slack",
    "workspace_ref" => "slack:T1"
  }

  test "a conversation's topics are keyed by the conversation, and none is lost to a shared key" do
    in_scratch_schema("scope_topics", fn repo, prefix ->
      migrate!(repo, prefix, @previous_version)

      older = topic!(repo, prefix, "emisar-mcp-access", "andrewdryga-andrewdryga", 1)
      newer = topic!(repo, prefix, "emisar-mcp-access", "andrewdryga-emisar", 2)
      other = topic!(repo, prefix, "livebook-status", "andrewdryga-emisar", 3)

      assert @version in migrate!(repo, prefix, @version)

      scope = CanonicalJSON.digest(@conversation)

      assert rows(repo, prefix) == %{
               newer => {scope, "emisar-mcp-access", KnowledgeAnchors.keys(scope, ["emisar"])},
               older => {scope, "emisar-mcp-access-2", KnowledgeAnchors.keys(scope, ["emisar"])},
               other => {scope, "livebook-status", KnowledgeAnchors.keys(scope, ["emisar"])}
             }

      assert rollback!(repo, prefix) == [@version]

      back = repository_scope("andrewdryga-andrewdryga")
      assert {^back, "emisar-mcp-access-2", _anchors} = rows(repo, prefix)[older]
    end)
  end

  defp topic!(repo, prefix, topic_key, repository_ref, minute) do
    id = Ecto.UUID.generate()
    scope = repository_scope(repository_ref)
    at = NaiveDateTime.add(~N[2026-09-27 15:00:00.000000], minute * 60)

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.conversation_knowledge
        (id, scope_key, topic_key, transport, workspace_ref, conversation_ref, repository_ref,
         visibility, state, version, source_generation, source_dependencies, source_input_id,
         latest_source_at, inserted_at, updated_at, anchor_keys)
      VALUES ($1, $2, $3, 'slack', 'slack:T1', 'slack:T1:C1', $4, 'public', $5, 1, 1, '[]',
              $6, $7, $7, $7, $8)
      """,
      [
        Ecto.UUID.dump!(id),
        scope,
        topic_key,
        repository_ref,
        Jason.encode!(%{
          "anchors" => ["emisar"],
          "summary" => "S",
          "title" => "T",
          "topics" => []
        }),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        at,
        KnowledgeAnchors.keys(scope, ["emisar"])
      ]
    )

    id
  end

  defp repository_scope(repository_ref),
    do: CanonicalJSON.digest(Map.put(@conversation, "repository_ref", repository_ref))

  defp rows(repo, prefix) do
    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT id, scope_key, topic_key, anchor_keys FROM #{prefix}.conversation_knowledge",
        []
      )

    Map.new(rows, fn [id, scope, key, anchors] -> {Ecto.UUID.load!(id), {scope, key, anchors}} end)
  end
end
