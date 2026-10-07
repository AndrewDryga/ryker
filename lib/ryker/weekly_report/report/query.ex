defmodule Ryker.WeeklyReport.Report.Query do
  @moduledoc "Each week's report, for every read of `weekly_reports`."
  use Ryker, :query
  alias Ryker.WeeklyReport.Report

  def all, do: from(reports in Report, as: :weekly_reports)

  def by_delivery_ref(queryable \\ all(), delivery_ref),
    do: where(queryable, [weekly_reports: r], r.delivery_ref == ^delivery_ref)

  @doc "The report of the week that starts on `week`; a preview is not it."
  def by_week(week),
    do: where(all(), [weekly_reports: r], r.week == ^week and not r.preview)

  def by_status(queryable \\ all(), status),
    do: where(queryable, [weekly_reports: r], r.status == ^status)

  @doc "Pending, with no retry backoff or claim lease left at `now`."
  def claimable_at(now) do
    :pending
    |> by_status()
    |> where(
      [weekly_reports: r],
      (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now) and
        (is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now)
    )
  end

  @doc "The next retry and the next lease expiry after `since` among pending reports."
  def select_next_due_after(since) do
    :pending
    |> by_status()
    |> select([weekly_reports: r], [
      filter(min(r.next_attempt_at), r.next_attempt_at > ^since),
      filter(min(r.lease_expires_at), r.lease_expires_at > ^since)
    ])
  end

  def ordered_by_due_at(queryable),
    do: order_by(queryable, [weekly_reports: r], asc: r.due_at, asc: r.id)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [weekly_reports: r], desc: r.updated_at, desc: r.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")
end
