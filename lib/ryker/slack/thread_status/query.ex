defmodule Ryker.Slack.ThreadStatus.Query do
  @moduledoc "Slack assistant thread statuses, for every read of `slack_thread_statuses`."
  import Ecto.Query
  alias Ryker.Slack.ThreadStatus

  def all, do: from(statuses in ThreadStatus, as: :slack_thread_statuses)

  def by_id(queryable \\ all(), id), do: where(queryable, [slack_thread_statuses: s], s.id == ^id)

  def by_workspace(queryable \\ all(), workspace_ref),
    do: where(queryable, [slack_thread_statuses: s], s.workspace_ref == ^workspace_ref)

  @doc """
  When `workspace_ref`'s statuses fall due after `since`, as `[next_attempt_at,
  lease_expires_at, delivered_at]`: a pending write's retry or lease, and the
  oldest delivery after `refresh_since` of a status still shown.
  """
  def next_due_after(workspace_ref, since, refresh_since) do
    from(status in by_workspace(workspace_ref),
      select: [
        filter(
          min(status.next_attempt_at),
          status.status == :pending and status.next_attempt_at > ^since
        ),
        filter(
          min(status.lease_expires_at),
          status.status == :pending and status.lease_expires_at > ^since
        ),
        filter(
          min(status.delivered_at),
          status.status == :delivered and status.desired_text != "" and
            status.delivered_at > ^refresh_since
        )
      ]
    )
  end

  @doc """
  The pending write of `workspace_ref` a worker takes next at `now`: due and
  unleased, the longest waiting first, skipping any another holds.
  """
  def next_claimable(workspace_ref, now) do
    from(status in by_workspace(workspace_ref),
      where:
        status.status == :pending and
          (is_nil(status.next_attempt_at) or status.next_attempt_at <= ^now) and
          (is_nil(status.lease_expires_at) or status.lease_expires_at <= ^now),
      order_by: [asc: status.updated_at, asc: status.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  def blocked(queryable \\ all()),
    do: where(queryable, [slack_thread_statuses: s], s.status == :blocked)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [slack_thread_statuses: s], desc: s.updated_at, desc: s.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
