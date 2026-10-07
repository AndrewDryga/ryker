defmodule Ryker.Delivery.RoutingResponseQuery do
  @moduledoc "What routing sent by itself, for every read of `delivery_routing_responses`."
  import Ecto.Query
  alias Ryker.Delivery.RoutingResponse

  def all, do: from(responses in RoutingResponse, as: :delivery_routing_responses)

  def by_input_id(queryable \\ all(), input_id),
    do: where(queryable, [delivery_routing_responses: r], r.input_id == ^input_id)

  def by_input_ids(queryable \\ all(), input_ids),
    do: where(queryable, [delivery_routing_responses: r], r.input_id in ^input_ids)

  def in_conversation(queryable \\ all(), transport, conversation_ref) do
    where(
      queryable,
      [delivery_routing_responses: r],
      r.transport == ^transport and r.conversation_ref == ^conversation_ref
    )
  end

  @doc "Messages routing sent that their platform received."
  def delivered_messages(queryable \\ all()) do
    where(
      queryable,
      [delivery_routing_responses: r],
      r.kind == :message and r.status == :delivered
    )
  end

  @doc "The message its platform named `message_ref` in its receipt."
  def by_receipt_message(queryable, message_ref) do
    where(
      queryable,
      [delivery_routing_responses: r],
      fragment("(?::jsonb)->>'message_ref' = ?", r.external_receipt, ^message_ref)
    )
  end

  def delivered_after(queryable, at),
    do: where(queryable, [delivery_routing_responses: r], r.delivered_at > ^at)

  def delivered_since(queryable, at),
    do: where(queryable, [delivery_routing_responses: r], r.delivered_at >= ^at)

  def delivered_before(queryable, at),
    do: where(queryable, [delivery_routing_responses: r], r.delivered_at < ^at)

  def latest_delivered_first(queryable),
    do: order_by(queryable, [delivery_routing_responses: r], desc: r.delivered_at, desc: r.id)

  def select_input_ids(queryable),
    do: select(queryable, [delivery_routing_responses: r], r.input_id)

  def select_input_deliveries(queryable),
    do: select(queryable, [delivery_routing_responses: r], {r.input_id, r.delivered_at})

  @doc "How many are in each status, as `{status, count}`."
  def count_by_status(queryable) do
    queryable
    |> group_by([delivery_routing_responses: r], r.status)
    |> select([delivery_routing_responses: r], {r.status, count(r.id)})
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
