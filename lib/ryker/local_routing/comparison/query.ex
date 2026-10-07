defmodule Ryker.LocalRouting.Comparison.Query do
  @moduledoc "The local routing model's answers beside routing's, for every read of `local_routing_comparisons`."
  import Ecto.Query
  alias Ryker.LocalRouting.Comparison

  def all, do: from(comparisons in Comparison, as: :local_routing_comparisons)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [local_routing_comparisons: c], c.id == ^id)

  def pending(queryable \\ all()),
    do: where(queryable, [local_routing_comparisons: c], c.status == :pending)

  @doc "Pending, with no retry backoff or attempt fence left at `now`."
  def due_at(now) do
    where(
      pending(),
      [local_routing_comparisons: c],
      is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now
    )
  end

  @doc "The next retry after `since` among pending comparisons."
  def select_next_due_after(since) do
    select(
      pending(),
      [local_routing_comparisons: c],
      filter(min(c.next_attempt_at), c.next_attempt_at > ^since)
    )
  end

  @doc "Comparisons of any of `identities` or quoting any of the messages and topics `keys` names."
  def from_sources_or_messages(queryable \\ all(), identities, keys) do
    where(
      queryable,
      [local_routing_comparisons: c],
      c.source_identity in ^identities or fragment("? && ?::text[]", c.message_keys, ^keys)
    )
  end

  def quoting_conversation(queryable \\ all(), conversation_ref) do
    where(
      queryable,
      [local_routing_comparisons: c],
      fragment("? @> ARRAY[?]::text[]", c.conversation_refs, ^conversation_ref)
    )
  end

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [local_routing_comparisons: c], asc: c.inserted_at, asc: c.id)

  def select_input_ids(queryable),
    do: select(queryable, [local_routing_comparisons: c], c.input_id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")
end
