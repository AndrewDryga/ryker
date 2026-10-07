defmodule Ryker.Observability.Projection.Query do
  @moduledoc """
  The query shapes observability projections share
  (`Ryker.Observability.Queues`, `Ryker.Observability.Fleet`): what is due,
  what is leased, how long the oldest has waited, and rows counted by a
  field. Each reads the first binding of the queryable it is given, whose
  rows carry the fields it names: a `status`, a retry time
  (`next_attempt_at`), a lease (`lease_ref`, `lease_expires_at`) and
  `updated_at`.
  """
  use Ryker, :query

  @doc "Rows in `statuses` whose retry, if any, is due at `now`."
  def due_in_statuses(queryable, statuses, now) do
    from(row in queryable,
      where: row.status in ^statuses,
      where: is_nil(row.next_attempt_at) or row.next_attempt_at <= ^now
    )
  end

  @doc "Rows whose retry, if any, is due at `now`."
  def retry_due_at(queryable, now),
    do: from(row in queryable, where: is_nil(row.next_attempt_at) or row.next_attempt_at <= ^now)

  @doc "Rows with no lease, or one that ran out by `now`."
  def unleased_at(queryable, now),
    do: from(row in queryable, where: is_nil(row.lease_ref) or row.lease_expires_at <= ^now)

  @doc "Rows with a lease still held at `now`."
  def leased_at(queryable, now),
    do: from(row in queryable, where: not is_nil(row.lease_ref) and row.lease_expires_at > ^now)

  @doc "Rows whose episode is among `episode_ids`, a query of episode ids."
  def by_episode_ids(queryable, episode_ids),
    do: from(row in queryable, where: row.episode_id in subquery(episode_ids))

  @doc "Rows that `rows`, another query of the same table, also reads."
  def among(queryable, rows) do
    ids = from(other in rows, select: other.id)
    from(row in queryable, where: row.id in subquery(ids))
  end

  def select_oldest_update(queryable), do: from(row in queryable, select: min(row.updated_at))

  @doc """
  When the oldest row fell due. A row that waits out a backoff or a poll
  interval falls due again when that wait ends, so it has waited since the
  later of `age_field` and its retry time. A follow-up's next poll is
  already its due time.
  """
  def select_oldest_due(queryable, :next_poll_at),
    do: from(row in queryable, select: min(row.next_poll_at))

  def select_oldest_due(queryable, age_field) do
    from(row in queryable,
      select: min(fragment("GREATEST(?, ?)", field(row, ^age_field), row.next_attempt_at))
    )
  end

  @doc "Rows of `queryable` counted by the value of `field`, as `{value, count}`."
  def counts_by(queryable, field) do
    from(row in queryable,
      group_by: field(row, ^field),
      order_by: field(row, ^field),
      select: {field(row, ^field), count(row.id)}
    )
  end
end
