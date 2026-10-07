defmodule Ryker.Admission.CandidateSearch.Query do
  @moduledoc """
  The indexed lanes routing searches for the episodes one input may belong
  to (`Ryker.Admission.CandidateSearch`), and the counts that weigh its words
  and identifiers. Every lane reads only what `eligible/2` allows.
  """
  import Ecto.Query
  alias Ryker.Episodes.{Episode, Origin, RoutingDigest}

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  @doc """
  The episodes `request` may be offered in correlation `scope`: of its
  execution mode, in a conversation the scope allows, with history kept.
  Active long-running work stays eligible whatever the history window says;
  the window only bounds how far completed history is offered.
  """
  def eligible(request, scope) do
    from(episode in Episode.Query.all(),
      where:
        episode.execution_mode == ^request.execution_mode and
          episode.destination_conversation_ref in ^scope.conversation_refs and
          is_nil(episode.history_pruned_at),
      where: episode.state in ^@active_states or episode.updated_at >= ^request.history_cutoff
    )
  end

  @doc "The `limit` eligible episodes that share the most of `anchors`, then the latest."
  def identity_lane(request, scope, anchors, limit) do
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
      limit: ^limit
    )
  end

  @doc """
  The `limit` eligible episodes of `request`'s thread, active ones first:
  those that answer there, and `origin_ids`, those with an input posted
  there. Thread gravity follows the exact transport, conversation and thread
  identity, never a bare timestamp: the same Slack thread_ts in two channels
  is two different threads.
  """
  def thread_lane(request, scope, origin_ids, limit) do
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
      limit: ^limit
    )
  end

  @doc "Up to `limit` episodes with an input posted in `request`'s exact thread."
  def thread_origin_ids(request, scope, limit) do
    from(origin in Origin,
      where:
        origin.transport == ^request.transport and
          origin.conversation_ref == ^scope.conversation_ref and
          origin.thread_ref == ^request.thread_ref,
      distinct: true,
      limit: ^limit,
      select: origin.episode_id
    )
  end

  @doc "The `limit` eligible episodes still active, the latest first."
  def recent_active_lane(request, scope, limit) do
    from(episode in eligible(request, scope),
      where: episode.state in ^@active_states,
      order_by: [desc: episode.updated_at, asc: episode.id],
      limit: ^limit
    )
  end

  @doc "The routing digests of the episodes `request` may be offered."
  def searchable(request, scope) do
    from(digest in RoutingDigest,
      join: episode in subquery(eligible(request, scope)),
      on: episode.id == digest.episode_id
    )
  end

  @doc "Of `searchable`'s digests, those whose words hold `lexeme`."
  def with_lexeme(searchable, lexeme) do
    from(digest in searchable,
      where:
        fragment("? @@ to_tsquery('simple', quote_literal(?))", digest.search_vector, ^lexeme)
    )
  end

  @doc "Of `searchable`'s digests, the anchor keys of those sharing any of `anchors`."
  def anchor_keys_sharing(searchable, anchors) do
    from(digest in searchable,
      where: fragment("? && ?::text[]", digest.anchor_keys, ^anchors),
      select: digest.anchor_keys
    )
  end

  @doc """
  The `limit` eligible episodes whose words match `terms`, a `to_tsquery`
  expression, as `{id, matched}`, most matched first. `matched` sums the
  rarity (`idfs`) of each of `lexemes` the work holds, weighted by where it
  appears by `field_weights` (title, opening or latest message, elsewhere).
  """
  def text_lane(request, scope, terms, {lexemes, idfs}, field_weights, limit) do
    %{"A" => a, "B" => b, "C" => c, "D" => d} = field_weights

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

    from(row in subquery(scored),
      order_by: [desc: row.matched, desc: row.updated_at, asc: row.id],
      limit: ^limit,
      select: {row.id, row.matched}
    )
  end

  @doc """
  The `limit` eligible episodes whose meaning vector from `model` is at
  least `floor` similar to `vector`, as `{id, similarity}`, the nearest
  first. The dot product of two normalized vectors is their cosine.
  """
  def meaning_lane(request, scope, model, vector, floor, limit) do
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

    from(row in subquery(scored),
      where: row.similarity >= ^floor,
      order_by: [desc: row.similarity, desc: row.updated_at, asc: row.id],
      limit: ^limit,
      select: {row.id, row.similarity}
    )
  end

  @doc "The similarity of each of `episode_ids` with a `model` vector to `vector`."
  def similarities(episode_ids, model, vector) do
    from(digest in RoutingDigest,
      where: digest.episode_id in ^episode_ids and digest.embedding_model == ^model,
      select:
        {digest.episode_id,
         fragment(
           "(SELECT sum(a * b)::float8 FROM unnest(?, ?::real[]) AS t(a, b))",
           digest.embedding,
           ^vector
         )}
    )
  end
end
