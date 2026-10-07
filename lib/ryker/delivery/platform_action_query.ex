defmodule Ryker.Delivery.PlatformActionQuery do
  @moduledoc "What Work posted or reacted with, for every read of `platform_actions`."
  import Ecto.Query
  alias Ryker.Delivery.PlatformAction

  def all, do: from(actions in PlatformAction, as: :platform_actions)

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

  @doc "The message its platform named `message_ref` in its receipt."
  def by_receipt_message(queryable, message_ref) do
    where(
      queryable,
      [platform_actions: a],
      fragment("(?::jsonb)->>'message_ref' = ?", a.external_receipt, ^message_ref)
    )
  end

  def latest_delivered_first(queryable),
    do: order_by(queryable, [platform_actions: a], desc: a.delivered_at, desc: a.id)

  def select_episode_ids(queryable), do: select(queryable, [platform_actions: a], a.episode_id)
  def limit_to(queryable, count), do: limit(queryable, ^count)
end
