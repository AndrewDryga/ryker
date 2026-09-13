defmodule Ryker.StateTools.LookupContext do
  @moduledoc false

  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.Slack.SourceRef
  alias Ryker.State.MemorySearch
  alias Ryker.StateTools.{LookupBoundary, LookupOriginals}

  @maximum_bytes 128 * 1_024

  # The platform has already checked source visibility. Keep this real binding;
  # the selected hit's channel is a relevance selector, never caller authority.
  def enrich(name, arguments, binding, result, source_tools)
      when name in [
             "search_slack",
             "read_slack_source",
             "search_github",
             "read_github_conversation"
           ] and is_map(binding) do
    Repo.transaction(fn -> enrich_in_transaction(arguments, binding, result, source_tools) end)
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in [
           :query_canceled,
           :lock_not_available,
           :deadlock_detected,
           :serialization_failure
         ],
         do: {:error, "memory_search_budget_exceeded"},
         else: reraise(error, __STACKTRACE__)
  end

  def enrich(_name, _arguments, _binding, result, _source_tools), do: {:ok, result}

  defp enrich_in_transaction(arguments, binding, result, source_tools) do
    Repo.query!("SET LOCAL statement_timeout = '5000ms'")

    with {:ok, binding, result} <- LookupBoundary.current(binding, result),
         {:ok, result} <- enrich_current(arguments, binding, result, source_tools) do
      result
    else
      {:error, reason} when is_atom(reason) -> Repo.rollback(Atom.to_string(reason))
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp enrich_current(arguments, binding, result, source_tools) do
    targets = targets(result, binding)

    if targets == [] do
      LookupOriginals.fit(result, @maximum_bytes)
    else
      binding = Map.put(binding, :source_tools, source_tools)

      case MemorySearch.related(binding, targets, arguments["before"]) do
        {:ok, related} -> attach(result, related)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp targets(result, %{
         episode: %{destination_transport: "slack", destination_conversation_ref: conversation}
       }) do
    ["slack", workspace, _channel] = String.split(conversation, ":", parts: 3)

    result
    |> anchors()
    |> Enum.flat_map(fn anchor ->
      case SourceRef.parse(anchor["source_ref"], workspace) do
        {:ok, %{kind: :message} = source} ->
          [
            %{
              "conversation_ref" => "slack:#{workspace}:#{source.channel_ref}",
              "thread_ref" =>
                anchor["thread_ts"] || thread_root(result, anchor, source, workspace),
              "message_ref" => source.message_ref
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp targets(result, %{
         episode: %{
           destination_transport: "control_plane",
           destination_conversation_ref: "control-plane:lab:" <> _id = conversation
         }
       }) do
    result
    |> anchors()
    |> Enum.map(
      &%{
        "conversation_ref" => conversation,
        "thread_ref" => conversation,
        "message_ref" => &1["source_ref"]
      }
    )
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp targets(_result, _binding), do: []

  defp anchors(result) do
    if result["anchor"],
      do: [result["anchor"]],
      else: get_in(result, ["results", "messages"]) || result["messages"] || []
  end

  defp thread_root(result, anchor, source, workspace) do
    channel = source.channel_ref

    case SourceRef.parse(anchor["thread_source_ref"] || result["source_ref"], workspace) do
      {:ok, %{kind: :thread, channel_ref: ^channel, message_ref: root}} -> root
      _ -> nil
    end
  end

  defp attach(result, related) do
    base = Map.merge(result, %{"related_memory" => [], "memory_coverage" => related["coverage"]})

    with {:ok, base} <- LookupOriginals.fit(base, @maximum_bytes) do
      budget = @maximum_bytes - byte_size(CanonicalJSON.encode!(base))
      {:ok, attach_within_budget(base, related["memories"], budget)}
    end
  end

  defp attach_within_budget(base, memories, budget) do
    {documents, _bytes} =
      Enum.reduce(memories, {[], 0}, fn document, {selected, bytes} ->
        size = byte_size(CanonicalJSON.encode!(document)) + 1

        if bytes + size <= budget,
          do: {[document | selected], bytes + size},
          else: {selected, bytes}
      end)

    result = Map.put(base, "related_memory", Enum.reverse(documents))

    if length(documents) < length(memories),
      do: put_in(result, ["memory_coverage", "status"], "partial"),
      else: result
  end
end
