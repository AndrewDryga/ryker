defmodule Ryker.Delivery.RoutingResponseQuery do
  @moduledoc "What routing sent by itself, for every read of `delivery_routing_responses`."
  import Ecto.Query
  alias Ryker.Delivery.RoutingResponse

  def all, do: from(responses in RoutingResponse, as: :delivery_routing_responses)

  def by_delivery_ref(queryable \\ all(), delivery_ref),
    do: where(queryable, [delivery_routing_responses: r], r.delivery_ref == ^delivery_ref)

  def pending(queryable \\ all()),
    do: where(queryable, [delivery_routing_responses: r], r.status == :pending)

  @doc """
  The responses a worker may send now: those whose every earlier response
  for the same input is delivered. The claim and the queue gauges read this
  one rule, so a response waiting its turn is never counted as stalled work.
  """
  def in_order(queryable \\ all()) do
    where(
      queryable,
      [delivery_routing_responses: r],
      not exists(
        from(earlier in RoutingResponse,
          where:
            earlier.input_id == parent_as(:delivery_routing_responses).input_id and
              earlier.position < parent_as(:delivery_routing_responses).position and
              earlier.status != :delivered,
          select: 1
        )
      )
    )
  end

  @doc "Pending and due at `now`: no retry backoff and no live claim left."
  def claimable_at(queryable, now) do
    queryable
    |> pending()
    |> where(
      [delivery_routing_responses: r],
      (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now) and
        (is_nil(r.lease_ref) or r.lease_expires_at <= ^now)
    )
  end

  @doc "The next retry and the next lease expiry after `since` among pending responses."
  def next_due_after(since) do
    select(pending(), [delivery_routing_responses: r], [
      filter(min(r.next_attempt_at), r.next_attempt_at > ^since),
      filter(min(r.lease_expires_at), not is_nil(r.lease_ref) and r.lease_expires_at > ^since)
    ])
  end

  def oldest_first(queryable) do
    order_by(queryable, [delivery_routing_responses: r],
      asc: r.inserted_at,
      asc: r.position,
      asc: r.id
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")

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
  def with_status(queryable, status),
    do: where(queryable, [delivery_routing_responses: r], r.status == ^status)

  def recently_updated_first(queryable),
    do: order_by(queryable, [delivery_routing_responses: r], desc: r.updated_at, desc: r.id)

  def delivered(queryable),
    do: where(queryable, [delivery_routing_responses: r], r.status == :delivered)

  def in_position_order(queryable),
    do: order_by(queryable, [delivery_routing_responses: r], asc: r.position)

  @doc "Each delivered response as `{delivered_at, kind, document}`."
  def select_deliveries(queryable) do
    select(
      queryable,
      [delivery_routing_responses: r],
      {r.delivered_at, r.kind, r.document}
    )
  end

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
