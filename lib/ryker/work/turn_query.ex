defmodule Ryker.Work.TurnQuery do
  @moduledoc "Work turns, for every read of `episode_work_turns`."
  import Ecto.Query
  alias Ryker.Work.Turn

  def all, do: from(turns in Turn, as: :episode_work_turns)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_work_turns: t], t.id == ^id)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_work_turns: t], t.episode_id == ^episode_id)

  def by_episode_ids(queryable \\ all(), episode_ids),
    do: where(queryable, [episode_work_turns: t], t.episode_id in ^episode_ids)

  def excluding_ids(queryable, ids),
    do: where(queryable, [episode_work_turns: t], t.id not in ^ids)

  @doc "Turns whose reply was delivered."
  def delivered(queryable \\ all()),
    do: where(queryable, [episode_work_turns: t], not is_nil(t.delivered_at))

  def delivered_after(queryable, at),
    do: where(queryable, [episode_work_turns: t], t.delivered_at > ^at)

  def delivered_since(queryable, at),
    do: where(queryable, [episode_work_turns: t], t.delivered_at >= ^at)

  def delivered_before(queryable, at),
    do: where(queryable, [episode_work_turns: t], t.delivered_at < ^at)

  def select_episode_deliveries(queryable),
    do: select(queryable, [episode_work_turns: t], {t.episode_id, t.delivered_at})

  def newest_first(queryable),
    do: order_by(queryable, [episode_work_turns: t], desc: t.inserted_at, desc: t.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def select_statuses(queryable), do: select(queryable, [episode_work_turns: t], t.status)

  @doc "Each episode's latest Work turn, as an automation's runs show it."
  def latest_per_episode do
    from(t in all(),
      distinct: t.episode_id,
      order_by: [asc: t.episode_id, desc: t.inserted_at, desc: t.id],
      select: %{
        accepted_at: t.accepted_at,
        delivered_at: t.delivered_at,
        episode_id: t.episode_id,
        failure_code: t.last_error_code,
        failure_detail: t.last_error_detail,
        finished_at: t.remote_finished_at,
        started_at: t.remote_started_at,
        turn_status: t.status,
        work_attempt_count: t.work_attempt_count
      }
    )
  end

  @doc "Settled, with the briefing and the accepted result still kept."
  def settled_with_bodies(queryable) do
    where(
      queryable,
      [episode_work_turns: t],
      t.status == :settled and is_nil(t.operational_pruned_at) and not is_nil(t.submission) and
        not is_nil(t.candidate)
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
end
