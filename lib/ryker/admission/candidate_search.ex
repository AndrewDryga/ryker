defmodule Ryker.Admission.CandidateSearch do
  @moduledoc """
  Bounded, indexed, explainable retrieval of episodes one input may belong to.

  Five indexed lanes fill a pool of at most 200 eligible episodes, each lane
  returning its own best 50 by relevance rather than the newest rows overall:
  shared links and identifiers, this thread, wording weighted by how rare each
  word is, meaning (`Ryker.Embeddings`, when a server is set up), and running
  work. The exact source item's existing owner is resolved separately so no
  lane cap can hide it. Ranking then chooses at most twenty options, reserving
  places for the strongest matches outside the incoming thread, and records
  why the cutoff fell where it did. The routing search benchmark
  (test/ryker/admission/search_benchmark_test.exs) measures all of it.
  """

  import Ecto.Query

  alias Ryker.Admission.{CorrelationScope, Ranking}

  alias Ryker.Episodes.{
    CorrelationClaims,
    Episode,
    Origin,
    Origins,
    RoutingDigest,
    RoutingDigests
  }

  alias Ryker.Repo
  alias Ryker.Work.Session

  @lane_limit 50
  @pool_limit 200
  # A word in more than a quarter of the searchable work (and in more than
  # three pieces of it) says little about which one a message is about.
  @common_share 0.25
  @common_floor 3
  # How much a word counts where it appears: in Ryker's title for the work,
  # in its opening or latest message, or elsewhere in its messages.
  @field_weight %{"A" => 1.0, "B" => 0.7, "C" => 0.5, "D" => 0.3}
  @thread_origin_limit 200
  @active_states [:working, :waiting_for_input, :waiting_for_event]
  @lanes [:identity, :thread, :text, :meaning, :recent_active]
  # Below this, bge-m3 finds unrelated text about as similar (the routing
  # search benchmark: unrelated pairs 0.3-0.45, related 0.55-0.8).
  @meaning_floor 0.4

  @type pooled :: %{
          episode: Episode.t(),
          digest: RoutingDigest.t() | nil,
          lanes: [atom()],
          text_rank: float(),
          meaning: float(),
          anchor_overlap: non_neg_integer(),
          reference_weights: [float()],
          origin_in_thread: boolean(),
          source_owner: boolean(),
          claims: [map()],
          repository_ref: String.t() | nil
        }

  @doc """
  Returns the ranked shortlist plus the receipt describing how it was found.
  """
  @spec search(map()) :: %{selected: [pooled()], pool: [pooled()], receipt: map()}
  def search(request) do
    scope = request.scope
    identifiers = request[:identifiers] || RoutingDigests.identifiers([request.text])
    anchors = RoutingDigests.anchor_keys(identifiers)
    words = RoutingDigests.search_words(request.text)
    weights = word_weights(request, scope, words)

    ranked_text = text_lane(request, scope, weights)
    ranked_meaning = meaning_lane(request, scope)

    lanes =
      %{
        identity: identity_lane(request, scope, anchors),
        thread: thread_lane(request, scope),
        text: Enum.map(ranked_text, &elem(&1, 0)),
        meaning: Enum.map(ranked_meaning, &elem(&1, 0)),
        recent_active: recent_active_lane(request, scope)
      }

    owner = source_owner(request)

    ranks = %{
      text: Map.new(ranked_text, fn {episode, rank} -> {episode.id, rank} end),
      meaning: Map.new(ranked_meaning, fn {episode, similarity} -> {episode.id, similarity} end)
    }

    pool = pool(lanes, owner, request, anchor_weights(request, scope, anchors), ranks)

    %{selected: selected, cutoff: cutoff} = Ranking.select(pool, request)

    %{
      selected: selected,
      # Everything examined, for tuning ranking on the benchmark.
      pool: pool,
      receipt:
        receipt(lanes, pool, selected, scope, cutoff, anchors)
        |> Map.merge(%{
          # What each lane searched with, so the search can be read back as
          # the words, links and places it used, not only as counts.
          "words" =>
            for({word, lexemes} <- weights.words, informative?(lexemes, weights), do: word),
          "common_words" =>
            for({word, lexemes} <- weights.words, not informative?(lexemes, weights), do: word),
          "identifiers" => Enum.take(identifiers, 16),
          "in_thread" => not is_nil(request.thread_ref),
          "meaning" => meaning_receipt(request),
          "history_since" => DateTime.to_iso8601(request.history_cutoff),
          "conversation_refs" => Enum.take(scope.conversation_refs, 32)
        })
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

  # How much each word of the message says, by how rare it is in the work
  # that could be offered: the BM25 inverse document frequency of its
  # English stem ("failing" and "failed" are one). Postgres ranks matches by
  # where words appear, never by how rare they are, so "change" or "week"
  # counted as much as "haproxy", and a new request dragged in unrelated
  # work that shared one ordinary word (the routing search benchmark).
  defp word_weights(_request, _scope, []), do: %{words: [], idf: %{}, informative: []}

  defp word_weights(request, scope, words) do
    stems = stems(words)
    lexemes = stems |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
    total = Repo.aggregate(searchable(request, scope), :count)

    counts =
      Map.new(lexemes, fn lexeme ->
        {lexeme,
         Repo.aggregate(
           from(digest in searchable(request, scope),
             where:
               fragment(
                 "? @@ to_tsquery('simple', quote_literal(?))",
                 digest.search_vector,
                 ^lexeme
               )
           ),
           :count
         )}
      end)

    idf = Map.new(counts, fn {lexeme, count} -> {lexeme, idf(total, count)} end)
    common = max(@common_floor, total * @common_share)

    %{
      words: stems,
      idf: idf,
      informative: for({lexeme, count} <- counts, count <= common, do: lexeme)
    }
  end

  defp stems(words) do
    Repo.query!(
      "SELECT word, tsvector_to_array(to_tsvector('english', word)) FROM unnest($1::text[]) AS word",
      [words]
    ).rows
    |> Enum.map(fn [word, lexemes] -> {word, lexemes} end)
  end

  defp idf(total, count), do: :math.log(1 + (total - count + 0.5) / (count + 0.5))

  defp informative?(lexemes, weights), do: Enum.any?(lexemes, &(&1 in weights.informative))

  defp searchable(request, scope) do
    from(digest in RoutingDigest,
      join: episode in subquery(eligible(request, scope)),
      on: episode.id == digest.episode_id
    )
  end

  defp text_lane(_request, _scope, %{informative: []}), do: []

  # Work that shares a telling word with the message, ranked by how much of
  # what the message says it covers: each shared word counts its rarity, more
  # in the work's title than in its opening or latest message, and more there
  # than elsewhere in its messages. The share of the message's rarity covered
  # is the work's topic fit, between 0 and 1.
  defp text_lane(request, scope, weights) do
    {lexemes, idfs} = weights.idf |> Enum.sort() |> Enum.unzip()
    total = Enum.sum(idfs)
    terms = Enum.map_join(weights.informative, " | ", &quote_lexeme/1)
    %{"A" => a, "B" => b, "C" => c, "D" => d} = @field_weight

    scored =
      from(episode in eligible(request, scope),
        join: digest in RoutingDigest,
        on: digest.episode_id == episode.id,
        where: fragment("? @@ to_tsquery('simple', ?)", digest.search_vector, ^terms),
        select: %{
          id: episode.id,
          updated_at: episode.updated_at,
          matched:
            fragment(
              """
              (SELECT coalesce(sum(q.idf * CASE
                  WHEN 'A' = ANY(u.weights) THEN ?::float8
                  WHEN 'B' = ANY(u.weights) THEN ?::float8
                  WHEN 'C' = ANY(u.weights) THEN ?::float8
                  ELSE ?::float8 END), 0)
               FROM unnest(?) AS u
               JOIN unnest(?::text[], ?::float8[]) AS q(lexeme, idf) ON q.lexeme = u.lexeme)
              """,
              ^a,
              ^b,
              ^c,
              ^d,
              digest.search_vector,
              ^lexemes,
              ^idfs
            )
        }
      )

    top =
      Repo.all(
        from(row in subquery(scored),
          order_by: [desc: row.matched, desc: row.updated_at, asc: row.id],
          limit: @lane_limit,
          select: {row.id, row.matched}
        )
      )

    ids = Enum.map(top, &elem(&1, 0))

    episodes =
      Map.new(Repo.all(from(episode in Episode, where: episode.id in ^ids)), &{&1.id, &1})

    Enum.map(top, fn {id, matched} -> {Map.fetch!(episodes, id), min(matched / total, 1.0)} end)
  end

  defp quote_lexeme(lexeme), do: "'" <> String.replace(lexeme, "'", "''") <> "'"

  # Work whose vector is near the message's (`Ryker.Embeddings`): the same
  # thing said in other words or another language. The dot product of two
  # normalized vectors is their cosine; only vectors from the same model are
  # compared.
  defp meaning_lane(%{meaning: %{vector: vector, model: model}} = request, scope)
       when is_list(vector) and is_binary(model) do
    scored =
      from(episode in eligible(request, scope),
        join: digest in RoutingDigest,
        on: digest.episode_id == episode.id,
        where: digest.embedding_model == ^model,
        select: %{
          id: episode.id,
          updated_at: episode.updated_at,
          similarity:
            fragment(
              "(SELECT sum(a * b)::float8 FROM unnest(?, ?::real[]) AS t(a, b))",
              digest.embedding,
              ^vector
            )
        }
      )

    top =
      Repo.all(
        from(row in subquery(scored),
          where: row.similarity >= ^@meaning_floor,
          order_by: [desc: row.similarity, desc: row.updated_at, asc: row.id],
          limit: @lane_limit,
          select: {row.id, row.similarity}
        )
      )

    ids = Enum.map(top, &elem(&1, 0))

    episodes =
      Map.new(Repo.all(from(episode in Episode, where: episode.id in ^ids)), &{&1.id, &1})

    Enum.map(top, fn {id, similarity} -> {Map.fetch!(episodes, id), similarity} end)
  end

  defp meaning_lane(_request, _scope), do: []

  # The cosine of every candidate with a vector, not only the ones the
  # meaning lane returned: a meaning far from the message tells ranking that
  # a shared word is a coincidence (`Ryker.Admission.Ranking`).
  defp similarities(%{meaning: %{vector: vector, model: model}}, ids)
       when is_list(vector) and ids != [] do
    Repo.all(
      from(digest in RoutingDigest,
        where: digest.episode_id in ^ids and digest.embedding_model == ^model,
        select:
          {digest.episode_id,
           fragment(
             "(SELECT sum(a * b)::float8 FROM unnest(?, ?::real[]) AS t(a, b))",
             digest.embedding,
             ^vector
           )}
      )
    )
    |> Map.new()
  end

  defp similarities(_request, _ids), do: %{}

  defp meaning_receipt(%{meaning: %{model: model, vector: vector}}) when is_list(vector),
    do: %{"model" => model}

  defp meaning_receipt(%{meaning: %{unavailable: reason}}), do: %{"unavailable" => reason}
  defp meaning_receipt(_request), do: nil

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
      where:
        episode.execution_mode == ^request.execution_mode and
          episode.destination_conversation_ref in ^scope.conversation_refs and
          is_nil(episode.history_pruned_at),
      where: episode.state in ^@active_states or episode.updated_at >= ^request.history_cutoff
    )
  end

  defp pool(lanes, owner, request, anchor_weights, ranks) do
    anchors = Map.keys(anchor_weights)

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
    similarities = similarities(request, Enum.map(episodes, & &1.id))

    grouped
    |> Enum.map(fn {id, {episode, found}} ->
      digest = Map.get(digests, id)

      %{
        episode: episode,
        digest: digest,
        lanes: Enum.uniq(found),
        text_rank: Map.get(ranks.text, id, 0.0),
        meaning: Map.get(similarities, id),
        anchor_overlap: anchor_overlap(digest, anchors),
        reference_weights: reference_weights(digest, anchor_weights),
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

  # How rare each of the message's links and identifiers is where it could belong, weighed as
  # words are: 1 for one only a single request names, falling as more do, and 0 once more than a
  # quarter of them do. Every shared identifier used to count alike, so nomad-hvn02, which 54
  # requests in the Blitz history name, outranked a perfect match in words (ID1, 2026-09-30).
  defp anchor_weights(_request, _scope, []), do: %{}

  defp anchor_weights(request, scope, anchors) do
    total = Repo.aggregate(searchable(request, scope), :count)
    common = max(@common_floor, total * @common_share)

    counts =
      from(digest in searchable(request, scope),
        where: fragment("? && ?::text[]", digest.anchor_keys, ^anchors),
        select: digest.anchor_keys
      )
      |> Repo.all()
      |> Enum.flat_map(&Enum.uniq/1)
      |> Enum.frequencies()

    Map.new(anchors, fn anchor ->
      count = Map.get(counts, anchor, 0)

      weight =
        if count > common, do: 0.0, else: idf(total, max(count, 1)) / idf(total, 1)

      {anchor, weight}
    end)
  end

  defp reference_weights(nil, _anchor_weights), do: []

  defp reference_weights(%RoutingDigest{anchor_keys: keys}, anchor_weights) do
    keys
    |> Enum.uniq()
    |> Enum.flat_map(fn key ->
      case Map.fetch(anchor_weights, key) do
        {:ok, weight} -> [weight]
        :error -> []
      end
    end)
    |> Enum.sort(:desc)
  end

  defp anchor_overlap(nil, _anchors), do: 0

  defp anchor_overlap(%RoutingDigest{anchor_keys: keys}, anchors),
    do: keys |> MapSet.new() |> MapSet.intersection(MapSet.new(anchors)) |> MapSet.size()
end
