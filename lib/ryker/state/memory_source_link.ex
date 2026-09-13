defmodule Ryker.State.MemorySourceLink do
  @moduledoc false
  import Ecto.Query
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Slack.SourceRef

  # Return a usable existing reader invocation, not an invented original quote.
  # The platform reader rechecks current source access when this is followed.
  def message("slack", conversation, message, thread)
      when is_binary(conversation) and is_binary(message) do
    with ["slack", workspace, channel] <- String.split(conversation, ":"),
         ref = "slack-source:v1:#{workspace}:#{channel}:message:#{message}",
         {:ok, _} <- SourceRef.parse(ref, workspace),
         {:ok, arguments} <- reader(ref, workspace, channel, thread) do
      %{
        "tool" => "read_slack_source",
        "arguments" => arguments
      }
    else
      _ -> nil
    end
  end

  def message("control_plane", "control-plane:lab:" <> _id = conversation, message, thread)
      when is_binary(message) and thread == conversation do
    if anchor = lab_anchor(conversation, message) do
      %{
        "tool" => "read_slack_source",
        "arguments" => %{
          "source_ref" => conversation,
          "anchor_ref" => anchor,
          "view" => "thread",
          "limit" => 20
        }
      }
    end
  end

  def message(_, _, _, _), do: nil

  @doc "Bounded original navigation for a source-backed document; its owner retains custody checks."
  def sources([]), do: []

  def sources(dependencies) do
    # A source receipt can be valid without an optional retained excerpt.
    # Known deletions, unlike absent excerpts, cannot supply an original link.
    Repo.query!(
      """
      SELECT o.transport, o.conversation_ref, o.source_message_ref, o.thread_ref
      FROM conversation_observations o
      LEFT JOIN ingress_inbox_entries i ON i.id = o.source_input_id
      WHERE (i.id IS NULL OR i.event_kind != 'delete') AND o.id IN (
        SELECT CASE WHEN pg_input_is_valid(root->>'observation_id', 'uuid')
          THEN (root->>'observation_id')::uuid ELSE NULL END
        FROM ryker_learning_roots($1) root
      )
      ORDER BY o.occurred_at DESC, o.id DESC
      LIMIT 3
      """,
      [CanonicalJSON.encode!(dependencies)]
    ).rows
    |> Enum.map(fn [transport, conversation, original, thread] ->
      message(transport, conversation, original, thread)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp lab_anchor(_conversation, "admit_input:" <> _ = ref), do: ref
  defp lab_anchor(_conversation, "delivery:" <> _ = ref), do: ref

  defp lab_anchor(conversation, message) do
    # Observation receipts name the native source item; the Lab reader names
    # the admitted event. Resolve that durable relation, never invent a locator.
    Repo.one(
      from(event in Event,
        join: episode in Episode,
        on: episode.id == event.episode_id,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^conversation and
            episode.destination_thread_ref == ^conversation and event.kind == :input_admitted,
        where:
          fragment(
            "?::jsonb #>> '{payload,source_item_ref}' = ? OR ?::jsonb ->> 'native_input_id' = ?",
            event.payload,
            ^message,
            event.payload,
            ^message
          ),
        order_by: [
          desc: fragment("(?::jsonb ->> 'revision')::bigint", event.payload),
          desc: event.occurred_at,
          desc: event.id
        ],
        limit: 1,
        select: event.dedupe_key
      )
    )
  end

  def context_targets(%{"conversation_ref" => conversation} = document)
      when is_binary(conversation) do
    direct =
      if document["thread_ref"] || document["source_message_ref"],
        do: [
          %{
            "conversation_ref" => conversation,
            "thread_ref" => document["thread_ref"],
            "message_ref" => document["source_message_ref"]
          }
        ],
        else: []

    case String.split(conversation, ":", parts: 3) do
      ["slack", workspace, _channel] ->
        reads = Enum.flat_map(document["source_reads"] || [], &read_target(&1, workspace))

        Enum.uniq(direct ++ reads)

      ["control-plane", "lab", _id] ->
        reads = Enum.flat_map(document["source_reads"] || [], &lab_read_target(&1, conversation))
        Enum.uniq(direct ++ reads)

      _ ->
        direct
    end
  end

  def context_targets(
        %{"source_ref" => "continuity-rollup:" <> _, "workspace_ref" => "slack:" <> workspace} =
          document
      ),
      do:
        Enum.flat_map(document["source_reads"] || [], &read_target(&1, workspace)) |> Enum.uniq()

  # A compacted Lab rollup is scoped by its own conversation rather than a Slack
  # workspace. Without this clause the descriptors a caller could follow while
  # the memory was still a summary became no targets at all after compaction.
  def context_targets(
        %{
          "source_ref" => "continuity-rollup:" <> _,
          "workspace_ref" => "control-plane:lab:" <> _ = conversation
        } = document
      ),
      do:
        Enum.flat_map(document["source_reads"] || [], &lab_read_target(&1, conversation))
        |> Enum.uniq()

  def context_targets(_document), do: []

  defp lab_read_target(
         %{"arguments" => %{"source_ref" => conversation, "anchor_ref" => anchor}},
         conversation
       ),
       do: [
         %{
           "conversation_ref" => conversation,
           "thread_ref" => conversation,
           "message_ref" => anchor
         }
       ]

  defp lab_read_target(_read, _conversation), do: []

  defp read_target(read, workspace) do
    case SourceRef.parse(read["arguments"]["source_ref"], workspace) do
      {:ok, %{kind: kind} = source} when kind in [:message, :thread] ->
        [
          %{
            "conversation_ref" => "slack:#{workspace}:#{source.channel_ref}",
            "thread_ref" => if(kind == :thread, do: source.message_ref),
            "message_ref" => if(kind == :message, do: source.message_ref)
          }
        ]

      _ ->
        []
    end
  end

  def for_caller(document, binding) do
    reads =
      [document["source_read"] | document["source_reads"] || []]
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&available?(&1, binding))

    document
    |> then(fn doc ->
      if Map.has_key?(doc, "source_read"),
        do: Map.put(doc, "source_read", List.first(reads)),
        else: doc
    end)
    |> then(fn doc ->
      if Map.has_key?(doc, "source_reads"), do: Map.put(doc, "source_reads", reads), else: doc
    end)
  end

  defp available?(
         %{"tool" => "read_slack_source", "arguments" => %{"source_ref" => ref}},
         %{episode: %{destination_transport: "slack", destination_conversation_ref: conversation}} =
           binding
       ) do
    ["slack", workspace, _channel] = String.split(conversation, ":", parts: 3)

    "read_slack_source" in Map.get(binding, :source_tools, []) and
      match?({:ok, _}, SourceRef.parse(ref, workspace))
  end

  defp available?(
         %{"tool" => "read_slack_source", "arguments" => %{"source_ref" => ref}},
         %{episode: %{destination_transport: "control_plane", destination_conversation_ref: ref}} =
           binding
       ),
       do: "read_slack_source" in Map.get(binding, :source_tools, [])

  defp available?(_read, _binding), do: false

  defp reader(ref, _workspace, _channel, nil),
    do: {:ok, %{"source_ref" => ref, "view" => "surrounding", "limit" => 20}}

  defp reader(ref, workspace, channel, thread) when is_binary(thread) do
    thread_ref = "slack-source:v1:#{workspace}:#{channel}:thread:#{thread}"

    with {:ok, _} <- SourceRef.parse(thread_ref, workspace) do
      {:ok, %{"source_ref" => thread_ref, "anchor_ref" => ref, "view" => "thread", "limit" => 20}}
    end
  end

  defp reader(_ref, _workspace, _channel, _thread), do: {:error, :invalid_thread}
end
