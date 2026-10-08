defmodule Ryker.StateTools.LookupBoundary do
  @moduledoc false
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.StateTools.Binding

  def current(binding, result) do
    with {:ok, current} <- Binding.fetch_and_lock_current(binding) do
      excluded = queued_sources(current.episode, binding.episode.next_sequence)

      if Enum.any?([result["anchor"], result["thread_root"]], &excluded?(&1, excluded)) do
        {:error, :source_not_available}
      else
        {:ok, current, current_result(result, excluded)}
      end
    end
  end

  defp current_result(result, excluded) do
    {result, removed} = prune(result, excluded)
    if removed, do: Map.put(result, "complete", false), else: result
  end

  defp queued_sources(%{destination_transport: "slack"} = episode, sequence) do
    episode.id
    |> Episodes.Event.Query.by_episode_id()
    |> Episodes.Event.Query.admitted_since_or_queued(sequence, episode.queued_input_refs)
    |> Episodes.Event.Query.select_payloads()
    |> Repo.all()
    |> Enum.flat_map(&message_ref/1)
    |> MapSet.new()
  end

  defp queued_sources(_episode, _sequence), do: MapSet.new()

  defp message_ref(%{
         "payload" => %{
           "destination" => %{"transport" => "slack", "conversation_ref" => conversation},
           "source_item_ref" => message
         }
       })
       when is_binary(message) do
    case ConversationRef.parse_slack(conversation) do
      {:ok, workspace, channel} -> [Slack.SourceRef.message(workspace, channel, message)]
      :error -> []
    end
  end

  defp message_ref(_payload), do: []
  defp excluded?(%{"source_ref" => ref}, excluded), do: MapSet.member?(excluded, ref)

  defp excluded?(%{"tool" => "read_slack_source", "arguments" => arguments}, excluded),
    do: Enum.any?(~w(source_ref anchor_ref), &MapSet.member?(excluded, arguments[&1]))

  defp excluded?(_item, _excluded), do: false

  defp prune(items, excluded) when is_list(items) do
    Enum.reduce(items, {[], false}, fn item, {kept, removed} ->
      if excluded?(item, excluded) do
        {kept, true}
      else
        {item, changed} = prune(item, excluded)
        {[item | kept], removed or changed}
      end
    end)
    |> then(fn {kept, removed} -> {Enum.reverse(kept), removed} end)
  end

  defp prune(document, excluded) when is_map(document) do
    if excluded?(document, excluded), do: {nil, true}, else: prune_document(document, excluded)
  end

  defp prune(value, _excluded), do: {value, false}

  defp prune_document(document, excluded) do
    {document, removed} =
      Enum.reduce(document, {%{}, false}, fn {key, value}, {kept, removed} ->
        {value, changed} = prune(value, excluded)
        {Map.put(kept, key, value), removed or changed}
      end)

    document = if removed, do: partial(document), else: document
    {document, removed}
  end

  defp partial(document) do
    Enum.reduce(~w(coverage context_coverage), document, fn key, doc ->
      if is_map(doc[key]), do: Map.update!(doc, key, &Map.put(&1, "status", "partial")), else: doc
    end)
  end
end
