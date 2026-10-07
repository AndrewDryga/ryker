defmodule Ryker.Delivery.PlatformAction.Query do
  @moduledoc "What Work posted or reacted with, for every read of `platform_actions`."
  import Ecto.Query
  alias Ryker.Delivery.PlatformAction

  def all, do: from(actions in PlatformAction, as: :platform_actions)

  def by_action_ref(queryable \\ all(), action_ref),
    do: where(queryable, [platform_actions: a], a.action_ref == ^action_ref)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [platform_actions: a], a.episode_id == ^episode_id)

  def by_turn_id(queryable \\ all(), turn_id),
    do: where(queryable, [platform_actions: a], a.turn_id == ^turn_id)

  def by_tool(queryable, tool), do: where(queryable, [platform_actions: a], a.tool == ^tool)

  def by_action_refs(queryable, action_refs),
    do: where(queryable, [platform_actions: a], a.action_ref in ^action_refs)

  def select_action_refs(queryable), do: select(queryable, [platform_actions: a], a.action_ref)

  def pending(queryable \\ all()),
    do: where(queryable, [platform_actions: a], a.status == :pending)

  @doc "The next retry and the next lease expiry after `since` among pending actions."
  def next_due_after(since) do
    select(pending(), [platform_actions: a], [
      filter(min(a.next_attempt_at), a.next_attempt_at > ^since),
      filter(min(a.lease_expires_at), a.lease_expires_at > ^since)
    ])
  end

  @doc """
  What the latest reaction `emoji_name` delivered on `source_item_ref` in an
  episode did: "add" or "remove".
  """
  def latest_reaction_action(episode_id, conversation_ref, source_item_ref, emoji_name) do
    from(a in by_episode_id(episode_id),
      where:
        a.tool == :set_slack_reaction and a.kind == :reaction and a.status == :delivered and
          a.conversation_ref == ^conversation_ref and a.source_item_ref == ^source_item_ref and
          fragment("(?::jsonb) ->> 'emoji_name' = ?", a.document, ^emoji_name),
      order_by: [desc: a.delivered_at, desc: a.inserted_at],
      limit: 1,
      select: fragment("(?::jsonb) ->> 'action'", a.document)
    )
  end

  @doc """
  The oldest action a worker may send at `now`. A reaction or an update of
  `numbered_tools` waits until every earlier one of its kind in its turn is
  delivered, so they arrive in the order the model asked for them.
  """
  def next_claimable(now, numbered_tools) do
    earlier_undelivered =
      from(earlier in PlatformAction,
        where:
          earlier.turn_id == parent_as(:platform_actions).turn_id and
            earlier.tool == parent_as(:platform_actions).tool and
            earlier.host_slot < parent_as(:platform_actions).host_slot and
            earlier.status != :delivered,
        select: 1
      )

    from(a in pending(),
      where:
        (is_nil(a.next_attempt_at) or a.next_attempt_at <= ^now) and
          (is_nil(a.lease_expires_at) or a.lease_expires_at <= ^now),
      where: a.tool not in ^numbered_tools or not exists(earlier_undelivered),
      order_by: [asc: a.inserted_at, asc: a.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  def with_status(queryable, status),
    do: where(queryable, [platform_actions: a], a.status == ^status)

  def recently_updated_first(queryable),
    do: order_by(queryable, [platform_actions: a], desc: a.updated_at, desc: a.id)

  def oldest_first(queryable),
    do: order_by(queryable, [platform_actions: a], asc: a.inserted_at, asc: a.id)

  def in_slot_order(queryable), do: order_by(queryable, [platform_actions: a], asc: a.host_slot)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  @doc "The action turn `turn_id` took in host slot `host_slot`."
  def by_turn_slot(turn_id, host_slot) do
    where(
      all(),
      [platform_actions: a],
      a.turn_id == ^turn_id and a.host_slot == ^host_slot
    )
  end

  def in_conversation(queryable \\ all(), transport, conversation_ref) do
    where(
      queryable,
      [platform_actions: a],
      a.transport == ^transport and a.conversation_ref == ^conversation_ref
    )
  end

  @doc "Messages Work posted that their platform received."
  def delivered_messages(queryable \\ all()),
    do: where(queryable, [platform_actions: a], a.kind == :message and a.status == :delivered)

  @doc "Each delivered action as `{delivered_at, document}`."
  def select_deliveries(queryable),
    do: select(queryable, [platform_actions: a], {a.delivered_at, a.document})

  @doc "The message its platform named `message_ref` in its receipt."
  def by_receipt_message(queryable, message_ref) do
    where(
      queryable,
      [platform_actions: a],
      fragment("(?::jsonb)->>'message_ref' = ?", a.external_receipt, ^message_ref)
    )
  end

  def with_delivery_time(queryable),
    do: where(queryable, [platform_actions: a], not is_nil(a.delivered_at))

  def newest_first(queryable),
    do: order_by(queryable, [platform_actions: a], desc: a.inserted_at, desc: a.id)

  def latest_delivered_first(queryable),
    do: order_by(queryable, [platform_actions: a], desc: a.delivered_at, desc: a.id)

  def select_episode_ids(queryable), do: select(queryable, [platform_actions: a], a.episode_id)
  def limit_to(queryable, count), do: limit(queryable, ^count)
end
