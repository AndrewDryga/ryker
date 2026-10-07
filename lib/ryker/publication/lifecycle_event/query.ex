defmodule Ryker.Publication.LifecycleEvent.Query do
  @moduledoc "What happened to each published change, for every read of `episode_publication_lifecycle_events`."
  use Ryker, :query
  alias Ryker.Publication.LifecycleEvent

  def all, do: from(events in LifecycleEvent, as: :episode_publication_lifecycle_events)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [episode_publication_lifecycle_events: e], e.id == ^id)

  def by_publication_id(queryable \\ all(), publication_id) do
    where(
      queryable,
      [episode_publication_lifecycle_events: e],
      e.publication_id == ^publication_id
    )
  end

  def select_latest_occurrence(queryable),
    do: select(queryable, [episode_publication_lifecycle_events: e], max(e.occurred_at))

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [episode_publication_lifecycle_events: e], e.ref == ^ref)

  @doc "Review feedback recorded on `publication_id` for a message said at `occurred_at`, oldest first."
  def review_feedback(publication_id, occurred_at) do
    from(e in all(),
      where:
        e.publication_id == ^publication_id and e.kind == :review_feedback and
          e.occurred_at == ^occurred_at,
      order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  @doc "Notices still waiting to be delivered."
  def pending(queryable \\ all()),
    do: where(queryable, [episode_publication_lifecycle_events: e], e.delivery_state == :pending)

  @doc "Notices whose retry, if any, is due at `now` and whose lease, if any, ran out."
  def due_unleased_at(queryable, now) do
    where(
      queryable,
      [episode_publication_lifecycle_events: e],
      (is_nil(e.next_attempt_at) or e.next_attempt_at <= ^now) and
        (is_nil(e.lease_expires_at) or e.lease_expires_at <= ^now)
    )
  end

  @doc "When pending notices fall due after `since`, as `[next_attempt_at, lease_expires_at]`."
  def select_next_due_after(since) do
    from(e in pending(),
      select: [
        filter(min(e.next_attempt_at), e.next_attempt_at > ^since),
        filter(min(e.lease_expires_at), e.lease_expires_at > ^since)
      ]
    )
  end

  def ordered_by_oldest(queryable) do
    order_by(queryable, [episode_publication_lifecycle_events: e],
      asc: e.inserted_at,
      asc: e.id
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")
end
