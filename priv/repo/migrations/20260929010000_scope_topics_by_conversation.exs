defmodule Ryker.Repo.Migrations.ScopeTopicsByConversation do
  use Ecto.Migration

  import Ecto.Query

  # V10, 2026-09-28: a learned topic was keyed by its conversation and the
  # repository the conversation's work used when it was learned. #test's
  # "Emisar MCP access" topic was learned while the channel worked on one
  # repository; its environment then moved to another, no later pass was
  # offered the topic, and it kept saying Emisar access was unverified after
  # Ryker had used it. A topic is now its conversation's (`Ryker.Knowledge`):
  # every topic is re-keyed by transport, workspace and conversation, with its
  # anchors hashed under the new key. When two repositories of one
  # conversation had a topic under the same key, the newest keeps it and the
  # others become "<key>-2", "<key>-3": nothing is dropped.
  #
  # Rolling back re-keys every topic by its conversation and repository again;
  # a renamed key keeps its new name.

  @maximum_topic_key 160

  def up, do: rekey(fn row -> scope(row, [:transport, :workspace_ref, :conversation_ref]) end)

  def down,
    do:
      rekey(fn row ->
        scope(row, [:transport, :workspace_ref, :conversation_ref, :repository_ref])
      end)

  defp rekey(scope_key) do
    rows =
      repo().all(
        from(k in "conversation_knowledge",
          order_by: [desc: k.latest_source_at, asc: k.id],
          select: %{
            id: k.id,
            transport: k.transport,
            workspace_ref: k.workspace_ref,
            conversation_ref: k.conversation_ref,
            repository_ref: k.repository_ref,
            topic_key: k.topic_key,
            state: k.state
          }
        ),
        prefix: prefix()
      )

    rows
    |> Enum.map(&Map.put(&1, :scope_key, scope_key.(&1)))
    |> Enum.group_by(& &1.scope_key)
    |> Enum.each(fn {key, group} -> rekey_group(key, group) end)
  end

  # Newest first: the newest topic under a key keeps it.
  defp rekey_group(scope_key, rows) do
    Enum.reduce(rows, MapSet.new(), fn row, taken ->
      topic_key = free_key(row.topic_key, taken)
      anchors = row.state |> Jason.decode!() |> Map.get("anchors", [])

      repo().update_all(
        from(k in "conversation_knowledge", where: k.id == ^row.id),
        [
          set: [
            scope_key: scope_key,
            topic_key: topic_key,
            anchor_keys: Ryker.Knowledge.KnowledgeAnchors.keys(scope_key, anchors)
          ]
        ],
        prefix: prefix()
      )

      MapSet.put(taken, topic_key)
    end)
  end

  defp free_key(key, taken) do
    if MapSet.member?(taken, key) do
      Enum.find_value(2..10_000, fn n ->
        suffix = "-#{n}"
        candidate = String.slice(key, 0, @maximum_topic_key - byte_size(suffix)) <> suffix
        unless MapSet.member?(taken, candidate), do: candidate
      end)
    else
      key
    end
  end

  defp scope(row, fields) do
    row
    |> Map.take(fields)
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
    |> Ryker.CanonicalJSON.digest()
  end
end
