defmodule Ryker.Knowledge.KnowledgeSource.Query do
  @moduledoc "The observations each topic was learned from, for every read of `conversation_knowledge_sources`."
  use Ryker, :query
  alias Ryker.Knowledge.{ConversationKnowledge, KnowledgeSource}
  alias Ryker.Learning

  def all, do: from(sources in KnowledgeSource, as: :conversation_knowledge_sources)

  @doc "The sources of topic `knowledge_id` in its source generation `generation`."
  def by_generation(knowledge_id, generation) do
    where(
      all(),
      [conversation_knowledge_sources: s],
      s.knowledge_id == ^knowledge_id and s.generation == ^generation
    )
  end

  def by_knowledge_id(queryable \\ all(), knowledge_id),
    do: where(queryable, [conversation_knowledge_sources: s], s.knowledge_id == ^knowledge_id)

  def by_knowledge_ids(queryable \\ all(), knowledge_ids),
    do: where(queryable, [conversation_knowledge_sources: s], s.knowledge_id in ^knowledge_ids)

  @doc """
  Of topics `knowledge_ids`, the ones that still rest on a message outside
  `observation_ids` that nobody forgot, in their current generation.
  """
  def resting_elsewhere(knowledge_ids, observation_ids) do
    from(s in all(),
      join: k in ConversationKnowledge,
      on: k.id == s.knowledge_id and k.source_generation == s.generation,
      join: o in Learning.ConversationObservation,
      on: o.id == s.observation_id,
      where:
        s.knowledge_id in ^knowledge_ids and s.observation_id not in ^observation_ids and
          is_nil(o.forgotten_at),
      distinct: true,
      select: s.knowledge_id
    )
  end

  def select_distinct_observation_ids(queryable) do
    queryable
    |> distinct(true)
    |> select([conversation_knowledge_sources: s], s.observation_id)
  end

  @doc "Sources not yet marked as directly supporting their topic, by receipt fingerprint."
  def indirect(queryable, fingerprints) do
    where(
      queryable,
      [conversation_knowledge_sources: s],
      s.receipt_fingerprint in ^fingerprints and is_nil(s.direct_support_version)
    )
  end

  def select_support(queryable) do
    select(queryable, [conversation_knowledge_sources: s], %{
      receipt_fingerprint: s.receipt_fingerprint,
      direct_support_version: s.direct_support_version
    })
  end

  @doc """
  The observations that directly support the topics `eligible` selects, by
  its `id` and `source_generation`, evaluated once: flattening the join made
  PostgreSQL validate one topic's 128 roots once per source row.
  """
  def direct_observation_ids(eligible) do
    from(s in all(),
      join: k in "eligible_conversation_knowledge",
      on: k.id == s.knowledge_id and k.source_generation == s.generation,
      where: not is_nil(s.direct_support_version),
      select: s.observation_id
    )
    |> with_cte("eligible_conversation_knowledge", as: ^eligible, materialized: true)
  end

  @doc """
  The observations that directly support each of `knowledge_ids` in its
  current generation, with where and when each was said, oldest first.
  """
  def direct_support(knowledge_ids) do
    from(s in all(),
      join: k in ConversationKnowledge,
      on: k.id == s.knowledge_id and k.source_generation == s.generation,
      join: o in Learning.ConversationObservation,
      on: o.id == s.observation_id,
      where: s.knowledge_id in ^knowledge_ids and not is_nil(s.direct_support_version),
      order_by: [asc: o.id],
      select: %{
        knowledge_id: s.knowledge_id,
        id: o.id,
        retained_at: s.retained_at,
        occurred_at: o.occurred_at,
        transport: o.transport,
        conversation_ref: o.conversation_ref,
        thread_ref: o.thread_ref,
        source_message_ref: o.source_message_ref
      }
    )
  end

  @doc "Sources introduced by `version` that directly support their topic by then."
  def direct_through(queryable, version) do
    where(
      queryable,
      [conversation_knowledge_sources: s],
      s.introduced_version <= ^version and s.direct_support_version <= ^version
    )
  end

  def ordered_by_observation(queryable),
    do: order_by(queryable, [conversation_knowledge_sources: s], asc: s.observation_id)

  def select_observation_count(queryable) do
    select(
      queryable,
      [conversation_knowledge_sources: s],
      count(s.observation_id, :distinct)
    )
  end

  @doc """
  The sources that directly support topic `knowledge_id` and are
  `observation` itself or were said in its thread.
  """
  def direct_near(knowledge_id, observation) do
    thread =
      if observation.thread_ref,
        do: dynamic([conversation_observations: o], o.thread_ref == ^observation.thread_ref),
        else: dynamic(false)

    connected = dynamic([conversation_observations: o], o.id == ^observation.id or ^thread)

    from(s in all(),
      join: previous in Learning.ConversationObservation,
      as: :conversation_observations,
      on: previous.id == s.observation_id,
      where: s.knowledge_id == ^knowledge_id and not is_nil(s.direct_support_version),
      where: ^connected
    )
  end

  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
end
