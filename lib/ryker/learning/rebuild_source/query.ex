defmodule Ryker.Learning.RebuildSource.Query do
  @moduledoc """
  The messages a rebuild may relearn a topic from: each current original
  observation of the topic's conversation, with the inbox entry it came from.
  Every query starts from `Ryker.Learning.ConversationObservation.Query.all/0`
  and joins the entry as `:ingress_inbox_entries`.
  """
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Slack.ChannelMembership

  @doc """
  The sources of `topic`, with observations kept no longer than
  `retention_seconds` (nil keeps them). Current originals have no inherited
  prose to authorize. The exact observation revision is matched before
  pagination: a deleted or edited source cannot take a selectable row merely
  because its old inbox entry remains.
  """
  def by_topic(topic, retention_seconds) do
    topic
    |> scoped_originals()
    |> current_originals()
    |> unexpired_originals(retention_seconds)
    |> undeleted_destination(topic)
  end

  defp scoped_originals(topic) do
    from(o in ConversationObservation.Query.all(),
      join: e in Entry,
      as: :ingress_inbox_entries,
      on: e.id == o.source_input_id,
      # The conversation's messages, whatever repository each one's work used:
      # a topic is its conversation's (`Ryker.Knowledge`).
      where:
        o.transport == ^topic.transport and o.workspace_ref == ^topic.workspace_ref and
          o.conversation_ref == ^topic.conversation_ref,
      where:
        e.destination_transport == o.transport and
          e.destination_conversation_ref == o.conversation_ref and
          fragment("? IS NOT DISTINCT FROM ?", e.repository_ref, o.repository_ref)
    )
  end

  defp current_originals(queryable) do
    from([conversation_observations: o, ingress_inbox_entries: e] in queryable,
      where:
        e.status == :decided and e.event_kind != :delete and is_nil(e.operational_pruned_at) and
          not is_nil(e.content),
      where: e.revision == o.revision and e.event_fingerprint == o.source_fingerprint,
      where: is_nil(o.source_result_ref) or not like(o.source_result_ref, "source-conflict:%"),
      where: is_nil(o.forgotten_at)
    )
  end

  defp unexpired_originals(queryable, nil), do: queryable

  defp unexpired_originals(queryable, seconds) do
    where(
      queryable,
      [conversation_observations: o],
      o.updated_at > fragment("clock_timestamp() - (? * interval '1 second')", ^seconds)
    )
  end

  defp undeleted_destination(queryable, %{transport: "slack"} = topic) do
    deleted =
      from(m in ChannelMembership,
        where:
          m.status == :deleted and
            fragment("'slack:' || ? || ':' || ?", m.workspace_ref, m.channel_ref) ==
              ^topic.conversation_ref,
        where: not like(m.channel_ref, "D%"),
        select: 1
      )

    where(queryable, not exists(subquery(deleted)))
  end

  defp undeleted_destination(queryable, _topic), do: queryable

  @doc "Sources whose message mentions `search`, ignoring case."
  def mentioning(queryable, ""), do: queryable

  def mentioning(queryable, search) do
    where(
      queryable,
      [ingress_inbox_entries: e],
      fragment("strpos(lower(?::text), lower(?)) > 0", e.content, ^search)
    )
  end

  def by_entry_ids(queryable, ids),
    do: where(queryable, [ingress_inbox_entries: e], e.id in ^ids)

  def ordered_by_occurred_at_desc(queryable) do
    order_by(queryable, [conversation_observations: o, ingress_inbox_entries: e],
      desc: o.occurred_at,
      desc: e.id
    )
  end

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], asc: e.inserted_at, asc: e.id)

  @doc "Page `number` of `size` rows, counting from 1."
  def page(queryable, number, size),
    do: queryable |> offset(^((number - 1) * size)) |> limit(^size)

  def select_observations_and_entries(queryable),
    do: select(queryable, [conversation_observations: o, ingress_inbox_entries: e], {o, e})

  def select_entries(queryable), do: select(queryable, [ingress_inbox_entries: e], e)
  def select_entry_ids(queryable), do: select(queryable, [ingress_inbox_entries: e], e.id)
end
