defmodule Responder.Admission.Ranking do
  @moduledoc """
  Explicit, tested rank features for the bounded candidate shortlist.

  Recency is a tie-breaker, never the selector. Proven occurrence identity and
  direct source references outrank thread gravity, thread gravity outranks
  channel proximity, and every feature value is recorded so an inspector can
  say why an episode was offered and why the cutoff fell where it did.
  """

  @reserved_non_local 4

  @occurrence_identity 1_000
  @direct_reference 400
  @same_thread 300
  @topic_fit 200
  @same_conversation 60
  @active 40
  @recency 20
  @recency_window 30 * 24 * 60 * 60

  @type scored :: map()

  @spec select([map()], map()) :: %{selected: [scored()], cutoff: String.t()}
  def select(pool, request) do
    scored = Enum.map(pool, &score(&1, request))
    limit = request.candidate_limit

    {owners, rest} = Enum.split_with(scored, & &1.source_owner)
    owners = Enum.sort_by(owners, &ordering/1)
    remaining = max(limit - length(owners), 0)

    {reserved, common} = reserve_non_local(rest, remaining)

    ranked =
      (reserved ++ Enum.take(common, max(remaining - length(reserved), 0)))
      |> Enum.sort_by(&ordering/1)

    # Mandatory ownership is the first rank feature, not a tie-break: a revision
    # of an exact source item must reach the model ahead of anything a score
    # could put above it.
    selected = Enum.take(owners ++ ranked, limit)

    %{selected: selected, cutoff: cutoff(length(pool), length(selected), limit, reserved)}
  end

  # Reserved places exist so more than twenty nearby options cannot bury the
  # one matching episode in another thread or channel. They are given only to
  # candidates with real supporting evidence, never to arbitrary noise, and
  # unused places return to the common pool.
  defp reserve_non_local(candidates, 0), do: {[], candidates}

  defp reserve_non_local(candidates, remaining) do
    {non_local, local} = Enum.split_with(candidates, &(not &1.features.same_thread))

    supported =
      non_local
      |> Enum.filter(&supported_non_local?/1)
      |> Enum.sort_by(&ordering/1)
      |> Enum.take(min(@reserved_non_local, remaining))

    reserved_ids = MapSet.new(supported, & &1.episode.id)

    common =
      (local ++ non_local)
      |> Enum.reject(&MapSet.member?(reserved_ids, &1.episode.id))
      |> Enum.sort_by(&ordering/1)

    {supported, common}
  end

  defp supported_non_local?(candidate) do
    candidate.features.occurrence_identity or candidate.features.direct_reference > 0 or
      candidate.features.topic_fit > 0.0
  end

  defp cutoff(examined, offered, limit, reserved) do
    cond do
      offered < limit and examined == offered ->
        "every eligible candidate was offered"

      reserved != [] ->
        "bounded to #{limit} options after reserving #{length(reserved)} places for supported non-local matches"

      true ->
        "bounded to #{limit} highest-ranked of #{examined} eligible candidates"
    end
  end

  defp ordering(candidate), do: {-candidate.score, candidate.episode.id}

  @doc false
  @spec score(map(), map()) :: scored()
  def score(entry, request) do
    features = features(entry, request)

    score =
      value(features.occurrence_identity, @occurrence_identity) +
        min(features.direct_reference, 4) * div(@direct_reference, 4) +
        value(features.same_thread, @same_thread) +
        round(min(features.topic_fit, 1.0) * @topic_fit) +
        value(features.same_conversation, @same_conversation) +
        value(features.active, @active) +
        recency_points(features.age_seconds)

    entry
    |> Map.put(:features, features)
    |> Map.put(:score, score)
  end

  defp features(entry, request) do
    episode = entry.episode

    same_thread =
      request.thread_ref != nil and
        (entry.origin_in_thread or
           (episode.destination_transport == request.transport and
              episode.destination_conversation_ref == request.scope.conversation_ref and
              episode.destination_thread_ref == request.thread_ref))

    %{
      occurrence_identity: occurrence_identity?(entry, request),
      direct_reference: entry.anchor_overlap,
      same_thread: same_thread,
      topic_fit: entry.text_rank,
      same_conversation:
        episode.destination_conversation_ref == request.scope.conversation_ref and
          episode.destination_transport == request.transport,
      active: episode.state in [:working, :waiting_for_input, :waiting_for_event],
      age_seconds: DateTime.diff(request.now, episode.updated_at, :second),
      lanes: entry.lanes
    }
  end

  defp occurrence_identity?(%{claims: claims}, %{occurrences: occurrences})
       when occurrences != [] do
    claimed = MapSet.new(claims, &{&1.namespace, &1.occurrence_ref})
    Enum.any?(occurrences, &MapSet.member?(claimed, {&1.namespace, &1.occurrence_ref}))
  end

  defp occurrence_identity?(_entry, _request), do: false

  defp recency_points(age_seconds) when age_seconds <= 0, do: @recency

  defp recency_points(age_seconds) do
    remaining = @recency_window - min(age_seconds, @recency_window)
    round(@recency * remaining / @recency_window)
  end

  defp value(true, points), do: points
  defp value(false, _points), do: 0

  @doc false
  def reserved_non_local, do: @reserved_non_local

  @doc "The recorded feature values behind one offered candidate."
  @spec document(scored()) :: map()
  def document(candidate) do
    features = candidate.features

    %{
      "score" => candidate.score,
      "lanes" => Enum.map(features.lanes, &Atom.to_string/1),
      "occurrence_identity" => features.occurrence_identity,
      "direct_references" => features.direct_reference,
      "same_thread" => features.same_thread,
      "same_conversation" => features.same_conversation,
      "topic_fit" => Float.round(features.topic_fit * 1.0, 4),
      "active" => features.active,
      "source_owner" => candidate.source_owner
    }
  end
end
