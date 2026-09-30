defmodule Ryker.Admission.Ranking do
  @moduledoc """
  Explicit, tested rank features for the bounded candidate shortlist.

  Recency is a tie-breaker, never the selector. Proven occurrence identity and
  direct source references outrank thread gravity, thread gravity outranks
  channel proximity, and every feature value is recorded so an inspector can
  say why an episode was offered and why the cutoff fell where it did.
  """

  @reserved_non_local 4

  # Tuned on the routing search benchmark
  # (test/ryker/admission/search_benchmark_test.exs, RYKER_SEARCH_TUNE=1):
  # exact evidence first, a shared identifier worth more than any wording can
  # be, then how much of what the message says the work covers, in words or
  # in meaning, with where the work lives, whether it runs and how recent it
  # is only as tie-breakers. Before, running in the same channel was worth
  # 120 points with no match at all and outranked the work a message was
  # about.
  @weights %{
    occurrence_identity: 1_000,
    direct_reference: 350,
    more_references: 100,
    same_thread: 300,
    relevance: 200,
    same_conversation: 30,
    active: 30,
    recency: 30,
    # Recency halves every this many seconds: a message without a subject
    # ("any update on this?") belongs to the work that moved last, and a day
    # tells work of this morning from last week's.
    recency_half_life: 24 * 60 * 60,
    # bge-m3 cosines: unrelated text sits near 0.4-0.5, the same subject from 0.55.
    meaning_unrelated: 0.5,
    meaning_related: 0.75,
    # How much of a wording match stands when the meaning says the two are
    # unrelated: "this week" in a weather question is not the on-call rota.
    disagreement: 0.5,
    # Work found only by wording or meaning is offered from this relevance up.
    offer_relevance: 0.3
  }

  @type scored :: map()

  @doc "The weights ranking uses unless a request names others."
  @spec weights() :: map()
  def weights, do: @weights

  @spec select([map()], map()) :: %{selected: [scored()], cutoff: String.t()}
  def select(pool, request) do
    weights = Map.merge(@weights, Map.get(request, :weights, %{}))

    scored =
      pool |> Enum.map(&score(&1, request, weights)) |> Enum.filter(&offerable?(&1, weights))

    limit = request.candidate_limit

    {owners, rest} = Enum.split_with(scored, & &1.source_owner)
    owners = Enum.sort_by(owners, &ordering/1)
    remaining = max(limit - length(owners), 0)

    {reserved, common} = reserve_non_local(rest, remaining, weights)

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
  defp reserve_non_local(candidates, 0, _weights), do: {[], candidates}

  defp reserve_non_local(candidates, remaining, weights) do
    {non_local, local} = Enum.split_with(candidates, &(not &1.features.same_thread))

    supported =
      non_local
      |> Enum.filter(&supported_non_local?(&1, weights))
      |> Enum.sort_by(&ordering/1)
      |> Enum.take(min(@reserved_non_local, remaining))

    reserved_ids = MapSet.new(supported, & &1.episode.id)

    common =
      (local ++ non_local)
      |> Enum.reject(&MapSet.member?(reserved_ids, &1.episode.id))
      |> Enum.sort_by(&ordering/1)

    {supported, common}
  end

  defp supported_non_local?(candidate, weights) do
    candidate.features.occurrence_identity or candidate.features.reference_strength > 0 or
      candidate.features.relevance >= weights.offer_relevance
  end

  # Work that only shares a word or two, or is only vaguely alike, is not
  # offered: it cost routing tokens and a chance to join the wrong work.
  defp offerable?(%{source_owner: true}, _weights), do: true

  defp offerable?(%{features: features}, weights) do
    features.occurrence_identity or features.reference_strength > 0 or features.same_thread or
      features.active or features.relevance >= weights.offer_relevance
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
  @spec score(map(), map(), map()) :: scored()
  def score(entry, request, weights \\ @weights) do
    features = features(entry, request, weights)

    score =
      value(features.occurrence_identity, weights.occurrence_identity) +
        references_points(features.reference_weights, weights) +
        value(features.same_thread, weights.same_thread) +
        round(features.relevance * weights.relevance) +
        value(features.same_conversation, weights.same_conversation) +
        value(features.active, weights.active) +
        recency_points(features.age_seconds, weights)

    entry
    |> Map.put(:features, features)
    |> Map.put(:score, score)
  end

  defp features(entry, request, weights) do
    episode = entry.episode

    same_thread =
      request.thread_ref != nil and
        (entry.origin_in_thread or
           (episode.destination_transport == request.transport and
              episode.destination_conversation_ref == request.scope.conversation_ref and
              episode.destination_thread_ref == request.thread_ref))

    topic_fit = min(entry.text_rank, 1.0)
    similarity = Map.get(entry, :meaning)

    %{
      occurrence_identity: occurrence_identity?(entry, request),
      direct_reference: entry.anchor_overlap,
      # How rare the shared identifiers are where the message could belong, rarest first.
      reference_weights: Map.get(entry, :reference_weights, []),
      reference_strength: Enum.sum(Map.get(entry, :reference_weights, [])),
      same_thread: same_thread,
      topic_fit: topic_fit,
      meaning: similarity,
      relevance: relevance(topic_fit, similarity, weights),
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

  # The rarest shared identifier counts in full where only this request names it; the next
  # three add less. One most requests name adds nothing (`CandidateSearch`, ID1).
  defp references_points([], _weights), do: 0

  defp references_points([rarest | rest], weights) do
    round(
      rarest * weights.direct_reference +
        (rest |> Enum.take(3) |> Enum.sum()) * weights.more_references
    )
  end

  # How much of what the message says the work covers. Wording and meaning
  # each count, and both together count more; wording the meaning calls
  # unrelated counts for less. Work whose vector is not computed yet, or a
  # search without one, is judged by wording alone.
  defp relevance(topic_fit, nil, _weights), do: topic_fit

  defp relevance(topic_fit, similarity, weights) do
    fit =
      ((similarity - weights.meaning_unrelated) /
         (weights.meaning_related - weights.meaning_unrelated))
      |> max(0.0)
      |> min(1.0)

    if fit > 0,
      do: 1 - (1 - topic_fit) * (1 - fit),
      else: topic_fit * weights.disagreement
  end

  defp recency_points(age_seconds, weights) when age_seconds <= 0, do: weights.recency

  defp recency_points(age_seconds, weights),
    do: round(weights.recency * :math.pow(0.5, age_seconds / weights.recency_half_life))

  defp value(true, points), do: points
  defp value(false, _points), do: 0

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
      "meaning" => features.meaning && Float.round(features.meaning * 1.0, 4),
      "relevance" => Float.round(features.relevance * 1.0, 4),
      "active" => features.active,
      "source_owner" => candidate.source_owner
    }
  end
end
