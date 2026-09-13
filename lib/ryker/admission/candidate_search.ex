defmodule Ryker.Admission.CandidateSearch do
  @moduledoc """
  Bounded, indexed, explainable retrieval of episodes one input may belong to.

  Four indexed lanes fill a pool of at most 200 eligible episodes, each lane
  returning its own best 50 by relevance rather than the newest rows overall.
  The exact source item's existing owner is resolved separately so no lane cap
  can hide it. Ranking then chooses at most twenty options, reserving places
  for the strongest matches outside the incoming thread, and records why the
  cutoff fell where it did.
  """

  import Ecto.Query

  alias Ryker.Admission.{CorrelationScope, Ranking}

  alias Ryker.Episodes.{
    AssociationCorrection,
    CorrelationClaims,
    Episode,
    Origin,
    Origins,
    RoutingDigest,
    RoutingDigests
  }

  alias Ryker.Repo
  alias Ryker.State.KnowledgeAnchors
  alias Ryker.Work.Session

  @lane_limit 50
  @pool_limit 200
  @thread_origin_limit 200
  @active_states [:working, :waiting_for_input, :waiting_for_event]
  @lanes [:identity, :thread, :text, :recent_active]

  @type pooled :: %{
          episode: Episode.t(),
          digest: RoutingDigest.t() | nil,
          lanes: [atom()],
          text_rank: float(),
          anchor_overlap: non_neg_integer(),
          origin_in_thread: boolean(),
          source_owner: boolean(),
          claims: [map()],
          repository_ref: String.t() | nil
        }

  @doc """
  Returns the ranked shortlist plus the receipt describing how it was found.
  """
  @spec search(map()) :: %{selected: [pooled()], receipt: map()}
  def search(request) do
    scope = request.scope
    anchors = RoutingDigests.anchor_keys(KnowledgeAnchors.discover([request.text]))
    terms = RoutingDigests.search_terms(request.text)

    ranked_text = text_lane(request, scope, terms)

    lanes =
      %{
        identity: identity_lane(request, scope, anchors),
        thread: thread_lane(request, scope),
        text: Enum.map(ranked_text, &elem(&1, 0)),
        recent_active: recent_active_lane(request, scope)
      }

    owner = source_owner(request)
    ranks = Map.new(ranked_text, fn {episode, rank} -> {episode.id, rank} end)
    pool = pool(lanes, owner, request, anchors, ranks)

    %{selected: selected, cutoff: cutoff} = Ranking.select(pool, request)

    %{
      selected: selected,
      receipt: receipt(lanes, pool, selected, scope, cutoff, anchors)
    }
  end

  defp receipt(lanes, pool, selected, scope, cutoff, anchors) do
    %{
      "scope" => Atom.to_string(scope.kind),
      "eligible_conversations" => length(scope.conversation_refs),
      "scope_truncated" => scope.truncated,
      "source_anchors" => length(anchors),
      "lanes" =>
        Map.new(@lanes, fn lane ->
          rows = Map.fetch!(lanes, lane)

          {Atom.to_string(lane),
           %{"returned" => length(rows), "saturated" => length(rows) >= @lane_limit}}
        end),
      "examined" => length(pool),
      "offered" => length(selected),
      "omitted" => max(length(pool) - length(selected), 0),
      "pool_saturated" => length(pool) >= @pool_limit,
      "cutoff_reason" => cutoff
    }
  end

  defp source_owner(%{
         native_input_id: native_input_id,
         transport: transport,
         execution_mode: mode
       }) do
    case Origins.current_owner(native_input_id, transport, mode) do
      {%Episode{} = episode, _revision} -> episode
      nil -> nil
    end
  end

  defp identity_lane(_request, _scope, []), do: []

  defp identity_lane(request, scope, anchors) do
    from(episode in eligible(request, scope),
      join: digest in RoutingDigest,
      on: digest.episode_id == episode.id,
      where: fragment("? && ?::text[]", digest.anchor_keys, ^anchors),
      order_by: [
        desc:
          fragment(
            "cardinality(ARRAY(SELECT unnest(?) INTERSECT SELECT unnest(?::text[])))",
            digest.anchor_keys,
            ^anchors
          ),
        desc: episode.updated_at,
        asc: episode.id
      ],
      limit: @lane_limit
    )
    |> Repo.all()
  end

  defp thread_lane(%{thread_ref: nil}, _scope), do: []

  # Thread gravity follows the exact transport, conversation and thread
  # identity, never a bare timestamp: the same Slack thread_ts in two channels
  # is two different threads. An episode whose home is elsewhere still has
  # thread gravity here when one of its inputs was posted in this thread.
  defp thread_lane(request, scope) do
    origin_ids = thread_origin_ids(request, scope)

    from(episode in eligible(request, scope),
      where:
        (episode.destination_transport == ^request.transport and
           episode.destination_conversation_ref == ^scope.conversation_ref and
           episode.destination_thread_ref == ^request.thread_ref) or
          episode.id in ^origin_ids,
      order_by: [
        desc: episode.state in ^@active_states,
        desc: episode.updated_at,
        asc: episode.id
      ],
      limit: @lane_limit
    )
    |> Repo.all()
  end

  defp thread_origin_ids(%{thread_ref: nil}, _scope), do: []

  defp thread_origin_ids(request, scope) do
    Repo.all(
      from(origin in Origin,
        where:
          origin.effective and origin.transport == ^request.transport and
            origin.conversation_ref == ^scope.conversation_ref and
            origin.thread_ref == ^request.thread_ref,
        distinct: true,
        limit: @thread_origin_limit,
        select: origin.episode_id
      )
    )
  end

  defp text_lane(_request, _scope, ""), do: []

  defp text_lane(request, scope, terms) do
    from(episode in eligible(request, scope),
      join: digest in RoutingDigest,
      on: digest.episode_id == episode.id,
      where:
        fragment(
          "to_tsvector('simple', ?) @@ to_tsquery('simple', ?)",
          digest.search_text,
          ^terms
        ),
      order_by: [
        desc:
          fragment(
            "ts_rank_cd(to_tsvector('simple', ?), to_tsquery('simple', ?))",
            digest.search_text,
            ^terms
          ),
        desc: episode.updated_at,
        asc: episode.id
      ],
      limit: @lane_limit,
      select:
        {episode,
         fragment(
           "ts_rank_cd(to_tsvector('simple', ?), to_tsquery('simple', ?))",
           digest.search_text,
           ^terms
         )}
    )
    |> Repo.all()
  end

  defp recent_active_lane(request, scope) do
    from(episode in eligible(request, scope),
      where: episode.state in ^@active_states,
      order_by: [desc: episode.updated_at, asc: episode.id],
      limit: @lane_limit
    )
    |> Repo.all()
  end

  # Active long-running work stays eligible whatever the history window says;
  # the window only bounds how far completed history is offered.
  defp eligible(request, scope) do
    from(episode in Episode,
      as: :episode,
      where:
        episode.execution_mode == ^request.execution_mode and
          episode.destination_conversation_ref in ^scope.conversation_refs and
          is_nil(episode.history_pruned_at),
      where: episode.state in ^@active_states or episode.updated_at >= ^request.history_cutoff,
      # Work an audited correction merged into another episode is not offered
      # again. Its evidence belongs to the surviving episode now, and offering
      # both would recreate exactly the split the operator repaired.
      where:
        not exists(
          from(correction in AssociationCorrection,
            where:
              correction.kind == :merge and
                correction.source_episode_id == parent_as(:episode).id,
            select: 1
          )
        )
    )
  end

  defp pool(lanes, owner, request, anchors, ranks) do
    lane_entries =
      @lanes
      |> Enum.flat_map(fn lane ->
        lanes |> Map.fetch!(lane) |> Enum.map(&{&1, lane})
      end)

    grouped =
      Enum.reduce(lane_entries, %{}, fn {episode, lane}, acc ->
        Map.update(acc, episode.id, {episode, [lane]}, fn {stored, found} ->
          {stored, found ++ [lane]}
        end)
      end)

    grouped =
      case owner do
        nil -> grouped
        %Episode{} = episode -> Map.put_new(grouped, episode.id, {episode, [:source_owner]})
      end

    episodes = Enum.map(grouped, fn {_id, {episode, _lanes}} -> episode end)
    digests = RoutingDigests.fetch_many(Enum.map(episodes, & &1.id))
    claims = CorrelationClaims.active_by_episode(Enum.map(episodes, & &1.id))
    repositories = pinned_repositories(Enum.map(episodes, & &1.id))
    thread_origins = MapSet.new(thread_origin_ids(request, request.scope))

    grouped
    |> Enum.map(fn {id, {episode, found}} ->
      digest = Map.get(digests, id)

      %{
        episode: episode,
        digest: digest,
        lanes: Enum.uniq(found),
        text_rank: Map.get(ranks, id, 0.0),
        anchor_overlap: anchor_overlap(digest, anchors),
        origin_in_thread: MapSet.member?(thread_origins, id),
        source_owner: owner != nil and owner.id == id,
        claims: Map.get(claims, id, []),
        repository_ref: Map.get(repositories, id)
      }
    end)
    |> Enum.filter(&authorized?(&1, request))
    |> Enum.sort_by(&{not &1.source_owner, &1.episode.id})
    |> Enum.take(@pool_limit)
  end

  # Cross-conversation reading never widens an audience. An episode that has
  # gathered evidence anywhere outside this input's correlation scope is not
  # offered at all: its digest, title and existence would leak that scope.
  defp authorized?(%{source_owner: true}, _request), do: true

  defp authorized?(%{digest: nil} = entry, request),
    do: entry.episode.destination_conversation_ref in request.scope.conversation_refs

  defp authorized?(%{digest: digest} = entry, request) do
    entry.episode.destination_conversation_ref in request.scope.conversation_refs and
      CorrelationScope.eligible?(request.scope, digest.conversation_refs)
  end

  defp pinned_repositories([]), do: %{}

  defp pinned_repositories(episode_ids) do
    Repo.all(
      from(session in Session,
        where:
          session.episode_id in ^episode_ids and session.execution_kind == :work and
            not is_nil(session.repository_ref),
        order_by: [asc: session.inserted_at],
        select: {session.episode_id, session.repository_ref}
      )
    )
    |> Map.new()
  end

  defp anchor_overlap(nil, _anchors), do: 0

  defp anchor_overlap(%RoutingDigest{anchor_keys: keys}, anchors),
    do: keys |> MapSet.new() |> MapSet.intersection(MapSet.new(anchors)) |> MapSet.size()

  @doc false
  def lane_limit, do: @lane_limit

  @doc false
  def pool_limit, do: @pool_limit
end
