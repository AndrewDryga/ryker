defmodule Ryker.Admission.ConversationContext.Query do
  @moduledoc """
  What came before one message in the same place, for the backdrop routing
  decides it against (`Ryker.Admission.ConversationContext`): the messages
  Ryker kept, and what Ryker itself said there. `kind` is the place rule: a
  thread reply sees its own thread, a channel root sees top-level messages
  only, anything else its whole conversation. Everything is before the
  message's own occurrence and of its execution mode.
  """
  import Ecto.Query
  alias Ryker.Delivery.{PlatformAction, RoutingResponse}
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Work.Turn

  @doc """
  The `limit` latest kept messages before `entry` in its place, newest first.
  The cutoff is the triggering occurrence. Equal timestamps fall back to the
  captured source item so two messages in the same Slack second stay ordered.
  """
  def retained_predecessors(entry, kind, limit) do
    from(other in Entry.Query.all(),
      where:
        other.destination_transport == ^entry.destination_transport and
          other.destination_conversation_ref == ^entry.destination_conversation_ref and
          other.execution_mode == ^entry.execution_mode and
          other.id != ^entry.id and
          is_nil(other.operational_pruned_at),
      where: other.occurred_at < ^entry.occurred_at
    )
    |> tie_break(entry)
    |> entry_scope(entry, kind)
    |> order_by([ingress_inbox_entries: other],
      desc: other.occurred_at,
      desc: other.source_item_ref
    )
    |> limit(^limit)
  end

  # Two Slack messages can share a second. The captured item orders them, but
  # only when this source has one: a webhook occurrence has no item reference.
  defp tie_break(queryable, %Entry{source_item_ref: nil}), do: queryable

  defp tie_break(queryable, %Entry{} = entry) do
    from(other in queryable,
      or_where:
        other.destination_transport == ^entry.destination_transport and
          other.destination_conversation_ref == ^entry.destination_conversation_ref and
          other.execution_mode == ^entry.execution_mode and
          other.id != ^entry.id and
          is_nil(other.operational_pruned_at) and
          other.occurred_at == ^entry.occurred_at and
          other.source_item_ref < ^entry.source_item_ref
    )
  end

  defp entry_scope(queryable, entry, :thread_reply) do
    from(other in queryable, where: other.destination_thread_ref == ^entry.destination_thread_ref)
  end

  # A Slack root binds its own timestamp as its thread, so top-level messages
  # are exactly the entries whose captured item is their own thread.
  defp entry_scope(queryable, _entry, :channel_root),
    do: from(other in queryable, where: other.destination_thread_ref == other.source_item_ref)

  defp entry_scope(queryable, _entry, :conversation), do: queryable

  @doc "The latest kept revision of thread root `root_ref` in `entry`'s conversation."
  def retained_root(entry, root_ref) do
    from(other in Entry.Query.all(),
      where:
        other.destination_transport == ^entry.destination_transport and
          other.destination_conversation_ref == ^entry.destination_conversation_ref and
          other.execution_mode == ^entry.execution_mode and
          other.source_item_ref == ^root_ref and
          is_nil(other.operational_pruned_at),
      order_by: [desc: other.revision],
      limit: 1
    )
  end

  @doc """
  The `limit` latest Work replies delivered in `entry`'s place before it,
  each with its time, document, receipt and the episode it answered.
  """
  def delivered_replies(entry, kind, limit) do
    from(turn in Turn.Query.all(),
      join: episode in Episode,
      on: episode.id == turn.episode_id,
      where:
        not is_nil(turn.delivered_at) and turn.delivered_at < ^entry.occurred_at and
          is_nil(turn.operational_pruned_at) and
          episode.execution_mode == ^entry.execution_mode and
          fragment("(?::jsonb ->> 'transport')", turn.external_receipt) ==
            ^entry.destination_transport and
          fragment("(?::jsonb ->> 'conversation_ref')", turn.external_receipt) ==
            ^entry.destination_conversation_ref
    )
    |> reply_scope(entry, kind)
    |> order_by([episode_work_turns: turn], desc: turn.delivered_at)
    |> limit(^limit)
    |> select([episode_work_turns: turn], %{
      at: turn.delivered_at,
      document: turn.delivery_document,
      receipt: turn.external_receipt,
      request: %{"episode_id" => turn.episode_id}
    })
  end

  defp reply_scope(queryable, entry, :thread_reply) do
    from(turn in queryable,
      where:
        fragment("(?::jsonb ->> 'thread_ref')", turn.external_receipt) ==
          ^entry.destination_thread_ref
    )
  end

  defp reply_scope(queryable, _entry, :channel_root) do
    from(turn in queryable,
      where:
        fragment(
          "coalesce(?::jsonb ->> 'thread_ref', ?::jsonb ->> 'message_ref') = ?::jsonb ->> 'message_ref'",
          turn.external_receipt,
          turn.external_receipt,
          turn.external_receipt
        )
    )
  end

  defp reply_scope(queryable, _entry, :conversation), do: queryable

  @doc "The `limit` latest messages Work posted in `entry`'s place before it, as updates."
  def delivered_posts(entry, kind, limit) do
    from(action in PlatformAction.Query.all(),
      join: episode in Episode,
      on: episode.id == action.episode_id,
      where:
        action.kind == :message and action.status == :delivered and
          action.delivered_at < ^entry.occurred_at and
          episode.execution_mode == ^entry.execution_mode and
          action.transport == ^entry.destination_transport and
          action.conversation_ref == ^entry.destination_conversation_ref
    )
    |> post_scope(entry, kind)
    |> order_by([platform_actions: action], desc: action.delivered_at)
    |> limit(^limit)
    |> select([platform_actions: action], %{
      at: action.delivered_at,
      document: action.document,
      receipt: action.external_receipt,
      thread_ref: action.thread_ref
    })
  end

  @doc """
  The `limit` latest quick replies routing delivered in `entry`'s place
  before it, each with the message it answered.
  """
  def delivered_quick_replies(entry, kind, limit) do
    from(response in RoutingResponse.Query.all(),
      join: input in Entry,
      on: input.id == response.input_id,
      where:
        response.kind == :message and response.status == :delivered and
          response.delivered_at < ^entry.occurred_at and
          input.execution_mode == ^entry.execution_mode and
          response.transport == ^entry.destination_transport and
          response.conversation_ref == ^entry.destination_conversation_ref
    )
    |> post_scope(entry, kind)
    |> order_by([delivery_routing_responses: response], desc: response.delivered_at)
    |> limit(^limit)
    |> select([delivery_routing_responses: response], %{
      at: response.delivered_at,
      document: response.document,
      receipt: response.external_receipt,
      request: %{"input_id" => response.input_id},
      thread_ref: response.thread_ref
    })
  end

  defp post_scope(queryable, entry, :thread_reply),
    do: from(post in queryable, where: post.thread_ref == ^entry.destination_thread_ref)

  defp post_scope(queryable, _entry, :channel_root) do
    from(post in queryable,
      where:
        is_nil(post.thread_ref) or
          post.thread_ref == fragment("(?::jsonb ->> 'message_ref')", post.external_receipt)
    )
  end

  defp post_scope(queryable, _entry, :conversation), do: queryable
end
