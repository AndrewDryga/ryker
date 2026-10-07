defmodule Ryker.Knowledge.ConversationKnowledge.Query do
  @moduledoc "Topics learned in conversations, for every read of `conversation_knowledge`."
  import Ecto.Query
  alias Ryker.Knowledge.{ConversationKnowledge, KnowledgeSource}
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Slack.ChannelMembership

  def all, do: from(topics in ConversationKnowledge, as: :conversation_knowledge)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [conversation_knowledge: k], k.id == ^id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [conversation_knowledge: k], k.id in ^ids)

  @doc """
  Topics whose sources still hold: not forgotten, not pruned, with at least
  one source in their current generation and none changed, moved to another
  conversation or, with `retention_seconds`, kept past it.
  """
  def valid(retention_seconds) do
    # The full gate's stale statistics turned the inverse validity join into
    # 50 million pair comparisons for 10,000 roots. Keep every observation read
    # parameterized by its receipt; OFFSET 0 prevents flattening that lookup.
    observation =
      from(o in ConversationObservation,
        where: o.id == parent_as(:knowledge_membership).observation_id,
        offset: 0
      )

    invalid =
      from(s in KnowledgeSource,
        as: :knowledge_membership,
        left_lateral_join: o in subquery(observation),
        as: :knowledge_observation,
        on: true,
        where:
          s.knowledge_id == parent_as(:conversation_knowledge).id and
            s.generation == parent_as(:conversation_knowledge).source_generation,
        where:
          ^dynamic(
            [knowledge_membership: s],
            ^changed_source() or (not is_nil(s.direct_support_version) and ^changed_scope())
          ),
        select: 1
      )

    invalid = expire_memberships(invalid, retention_seconds)

    any =
      from(s in KnowledgeSource,
        where:
          s.knowledge_id == parent_as(:conversation_knowledge).id and
            s.generation == parent_as(:conversation_knowledge).source_generation,
        select: 1
      )

    from(k in all(),
      where: is_nil(k.forgotten_at),
      where: exists(subquery(any)) and not exists(subquery(invalid)),
      where: fragment(~s(?::jsonb <> '{"retention":"pruned"}'::jsonb), k.state)
    )
  end

  defp expire_memberships(invalid, nil), do: invalid

  defp expire_memberships(invalid, seconds) do
    or_where(
      invalid,
      [knowledge_membership: s, knowledge_observation: o],
      s.knowledge_id == parent_as(:conversation_knowledge).id and
        s.generation == parent_as(:conversation_knowledge).source_generation and
        (s.retained_at <= ago(^seconds, "second") or o.updated_at <= ago(^seconds, "second"))
    )
  end

  defp changed_source do
    dynamic(
      [knowledge_membership: s, knowledge_observation: o],
      is_nil(o.id) or o.revision != s.source_revision or
        o.source_fingerprint != s.source_fingerprint
    )
  end

  # A source moved to another conversation no longer supports the topic. Its
  # repository may differ: a topic is its conversation's.
  defp changed_scope do
    dynamic(
      [knowledge_observation: o],
      o.conversation_ref != parent_as(:conversation_knowledge).conversation_ref or
        o.workspace_ref != parent_as(:conversation_knowledge).workspace_ref
    )
  end

  @doc """
  A topic that is forgotten or expired gives its subject to the next topic
  learned about it; one still kept holds it.
  """
  def kept(queryable) do
    where(
      queryable,
      [conversation_knowledge: k],
      is_nil(k.forgotten_at) and
        fragment(~s(?::jsonb <> '{"retention":"pruned"}'::jsonb), k.state)
    )
  end

  def forgotten(queryable),
    do: where(queryable, [conversation_knowledge: k], not is_nil(k.forgotten_at))

  def unforgotten(queryable),
    do: where(queryable, [conversation_knowledge: k], is_nil(k.forgotten_at))

  @doc "Topics learned about repository `ref`, or about none for nil."
  def of_repository(queryable, nil),
    do: where(queryable, [conversation_knowledge: k], is_nil(k.repository_ref))

  def of_repository(queryable, repository_ref),
    do: where(queryable, [conversation_knowledge: k], k.repository_ref == ^repository_ref)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [conversation_knowledge: k], desc: k.updated_at, desc: k.id)

  def in_workspace(queryable, workspace_ref),
    do: where(queryable, [conversation_knowledge: k], k.workspace_ref == ^workspace_ref)

  @doc """
  Topics not forgotten whose current sources include any of observations
  `observation_ids`, as their ids in order.
  """
  def citing_observations(observation_ids) do
    from(k in all(),
      join: s in KnowledgeSource,
      on: s.knowledge_id == k.id and s.generation == k.source_generation,
      where: s.observation_id in ^observation_ids and is_nil(k.forgotten_at),
      distinct: true,
      order_by: k.id,
      select: k.id
    )
  end

  @doc """
  The update that forgets topics `ids` at `now`: their state becomes
  `erased_state`, and their key and anchors retire so that a later topic may
  take the subject.
  """
  def forget(ids, erased_state, now) do
    from(k in by_ids(ids),
      update: [
        set: [
          state: ^erased_state,
          forgotten_at: ^now,
          topic_key: fragment("'retired:' || ?::text", k.id),
          anchor_keys: ^[]
        ]
      ]
    )
  end

  def by_conversation_ref(queryable, conversation_ref),
    do: where(queryable, [conversation_knowledge: k], k.conversation_ref == ^conversation_ref)

  def in_conversation(queryable, transport, conversation_ref) do
    where(
      queryable,
      [conversation_knowledge: k],
      k.transport == ^transport and k.conversation_ref == ^conversation_ref
    )
  end

  def by_scope_key(queryable \\ all(), scope_key),
    do: where(queryable, [conversation_knowledge: k], k.scope_key == ^scope_key)

  def by_topic_key(queryable, topic_key),
    do: where(queryable, [conversation_knowledge: k], k.topic_key == ^topic_key)

  def by_topic_keys(queryable, topic_keys),
    do: where(queryable, [conversation_knowledge: k], k.topic_key in ^topic_keys)

  def by_anchor_keys(queryable, keys) do
    where(
      queryable,
      [conversation_knowledge: k],
      fragment("? && ?::text[]", k.anchor_keys, ^keys)
    )
  end

  @doc "Topics of `scope_key` with any of `topic_keys` or sharing an anchor with `anchor_keys`."
  def matching_topics_or_anchors(scope_key, topic_keys, anchor_keys) do
    where(
      all(),
      [conversation_knowledge: k],
      k.scope_key == ^scope_key and
        (k.topic_key in ^topic_keys or fragment("? && ?::text[]", k.anchor_keys, ^anchor_keys))
    )
  end

  @doc """
  Topics within the search scope a recall names: the workspace, the scope
  the pass may write (`scope_key`), this channel, or the repository.
  """
  def within_scope(queryable, _scope_key, _scope, "workspace"), do: queryable

  def within_scope(queryable, scope_key, _scope, "writable"),
    do: by_scope_key(queryable, scope_key)

  def within_scope(queryable, _scope_key, scope, "current_channel") do
    where(queryable, [conversation_knowledge: k], k.conversation_ref == ^scope.conversation_ref)
  end

  def within_scope(queryable, _scope_key, %{repository_ref: ref}, "repository")
      when is_binary(ref),
      do: where(queryable, [conversation_knowledge: k], k.repository_ref == ^ref)

  def within_scope(queryable, _scope_key, _scope, _search_scope), do: where(queryable, false)

  def matching(queryable, search) when is_binary(search) do
    search = String.slice(String.trim(search), 0, 200)

    where(
      queryable,
      [conversation_knowledge: k],
      fragment("position(lower(?) in lower(?)) > 0", ^search, k.state)
    )
  end

  def matching(queryable, _search), do: queryable

  @doc "Topics whose words match `terms`, a `to_tsquery` expression, the best matches first."
  def related_to(queryable, terms, conversation_ref) do
    from(k in queryable,
      where: fragment("to_tsvector('simple', ?) @@ to_tsquery('simple', ?)", k.state, ^terms),
      order_by: [
        desc:
          fragment(
            "ts_rank_cd(to_tsvector('simple', ?), to_tsquery('simple', ?))",
            k.state,
            ^terms
          ),
        desc: k.conversation_ref == ^conversation_ref,
        desc: k.latest_source_at,
        asc: k.id
      ]
    )
  end

  @doc """
  Topics of `scope_key` with a direct source said in thread or message
  `reference` of `conversation_ref`.
  """
  def supported_in_thread(queryable, scope_key, conversation_ref, reference) do
    direct_source =
      from(s in KnowledgeSource,
        join: o in ConversationObservation,
        on: o.id == s.observation_id,
        where:
          s.knowledge_id == parent_as(:conversation_knowledge).id and
            s.generation == parent_as(:conversation_knowledge).source_generation,
        where: not is_nil(s.direct_support_version),
        where: o.conversation_ref == ^conversation_ref,
        where: fragment("COALESCE(?, ?) = ?", o.thread_ref, o.source_message_ref, ^reference),
        select: 1
      )

    where(
      queryable,
      [conversation_knowledge: k],
      k.scope_key == ^scope_key and exists(subquery(direct_source))
    )
  end

  @doc """
  Of `local` and `inherited` topic ids, those a Slack channel may read: its
  own unless the channel was deleted, and those inherited from public
  channels while it is public itself.
  """
  def available_in_channel(local, inherited, workspace, channel) do
    membership =
      from([slack_channel_memberships: m] in ChannelMembership.Query.all(),
        where: m.workspace_ref == ^workspace and m.channel_ref == ^channel,
        select: 1
      )

    deleted = where(membership, [slack_channel_memberships: m], m.status == :deleted)

    public =
      where(
        membership,
        [slack_channel_memberships: m],
        m.status == :joined and not m.private and not m.external_shared
      )

    local = where(local, not exists(subquery(deleted)))
    inherited = where(inherited, exists(subquery(public)))
    union(local, ^inherited)
  end

  @doc "The fields a memory search reads from a topic (`Ryker.Memories.SearchPage.Query`)."
  def search_fields do
    %{
      text: dynamic([conversation_knowledge: k], k.state),
      changed: dynamic([conversation_knowledge: k], k.updated_at),
      source: dynamic([conversation_knowledge: k], k.latest_source_at)
    }
  end

  def ordered_by_latest_source_at_desc(queryable) do
    order_by(queryable, [conversation_knowledge: k], desc: k.latest_source_at, asc: k.id)
  end

  @doc "This conversation's topics first, then the latest learned."
  def ordered_by_conversation_and_latest_source(queryable, conversation_ref) do
    order_by(queryable, [conversation_knowledge: k],
      desc: k.conversation_ref == ^conversation_ref,
      desc: k.latest_source_at,
      asc: k.id
    )
  end

  def ordered_by_id(queryable), do: order_by(queryable, [conversation_knowledge: k], asc: k.id)
  def select_ids(queryable), do: select(queryable, [conversation_knowledge: k], k.id)

  def select_id_generations(queryable) do
    select(queryable, [conversation_knowledge: k], %{
      id: k.id,
      source_generation: k.source_generation
    })
  end

  @doc "Topics learned between `from` and `to` and not forgotten, newest first, with their conversation and state."
  def learned_between(from, to) do
    all()
    |> where(
      [conversation_knowledge: k],
      is_nil(k.forgotten_at) and k.inserted_at >= ^from and k.inserted_at < ^to
    )
    |> order_by([conversation_knowledge: k], desc: k.inserted_at, desc: k.id)
    |> select([conversation_knowledge: k], %{conversation: k.conversation_ref, state: k.state})
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
  def lock_for_share_skip_locked(queryable), do: lock(queryable, "FOR SHARE SKIP LOCKED")
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
