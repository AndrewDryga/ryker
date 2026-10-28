defmodule Ryker.Work.SourceDependencies do
  @moduledoc """
  The messages and topics a saved Work turn depends on for explicit forgetting.
  This reads dependency metadata, never a new prompt or an enriched historical
  answer. A confirmed task also depends on the request that offered it.
  Callers copying words hold RoutingExamples' shared forgetting lock first.
  """
  alias Ryker.{Episodes, Ingress, Learning, Repo, RoutingExamples, Work}

  @maximum_links 8

  @doc "The source identities, message keys and conversations, and whether any was forgotten."
  def read(%Episodes.Episode{} = episode, %Work.Turn{} = turn) do
    {inputs, complete?} = inputs(episode, turn)
    quoted = Enum.map(inputs, &RoutingExamples.quoted_keys/1)

    %{
      source_identities: inputs |> Enum.map(&Learning.Observations.source_identity/1) |> sorted(),
      message_keys: quoted |> Enum.flat_map(& &1.keys) |> sorted(),
      conversation_refs:
        quoted
        |> Enum.flat_map(& &1.conversations)
        |> Kernel.++(List.wrap(episode.destination_conversation_ref))
        |> sorted(),
      complete?: complete? and Enum.all?(inputs, &is_nil(&1.operational_pruned_at)),
      forgotten?: Enum.any?(inputs, &RoutingExamples.quotes_forgotten?/1)
    }
  end

  defp inputs(episode, turn) do
    {linked, complete?} =
      linked_inputs(episode.linked_episode_id, episode.inserted_at, @maximum_links)

    {admitted(episode.id, turn.inserted_at) ++ linked, complete?}
  end

  defp linked_inputs(nil, _until, _left), do: {[], true}
  defp linked_inputs(_episode_id, _until, 0), do: {[], false}

  defp linked_inputs(episode_id, until, left) do
    case Repo.fetch(Episodes.Episode.Query.by_id(episode_id)) do
      {:ok, %Episodes.Episode{history_pruned_at: nil} = source_episode} ->
        {linked, complete?} =
          linked_inputs(source_episode.linked_episode_id, source_episode.inserted_at, left - 1)

        {admitted(source_episode.id, until) ++ linked, complete?}

      _missing_or_pruned ->
        {[], false}
    end
  end

  defp admitted(episode_id, until),
    do: episode_id |> Ingress.Inbox.Entry.Query.admitted_to(until) |> Repo.all()

  defp sorted(values), do: values |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
end
