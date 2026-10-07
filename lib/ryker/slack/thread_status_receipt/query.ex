defmodule Ryker.Slack.ThreadStatusReceipt.Query do
  @moduledoc "What Slack answered to thread status writes, for every read of `slack_thread_status_receipts`."
  use Ryker, :query
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.ThreadStatusReceipt

  def all, do: from(receipts in ThreadStatusReceipt, as: :slack_thread_status_receipts)

  def by_thread(queryable \\ all(), workspace_ref, channel_ref, thread_ref) do
    where(
      queryable,
      [slack_thread_status_receipts: r],
      r.workspace_ref == ^workspace_ref and r.channel_ref == ^channel_ref and
        r.thread_ref == ^thread_ref
    )
  end

  @doc "Receipts of the writes made for `episode_id` or for one of its messages."
  def by_episode_id(episode_id) do
    inputs = episode_id |> Entry.Query.by_episode_id() |> Entry.Query.select_ids()

    where(
      all(),
      [slack_thread_status_receipts: r],
      (r.origin_kind == "episode" and r.origin_id == ^episode_id) or
        (r.origin_kind == "input" and r.origin_id in subquery(inputs))
    )
  end

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [slack_thread_status_receipts: r], asc: r.inserted_at, asc: r.id)

  def ordered_by_recent(queryable),
    do: order_by(queryable, [slack_thread_status_receipts: r], desc: r.inserted_at, desc: r.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
