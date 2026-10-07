defmodule Ryker.Work.TurnQuery do
  @moduledoc "Work turns, for every read of `episode_work_turns`."
  import Ecto.Query
  alias Ryker.Work.Turn

  def all, do: from(turns in Turn, as: :episode_work_turns)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_work_turns: t], t.id == ^id)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_work_turns: t], t.episode_id == ^episode_id)

  def by_turn_ref(queryable, turn_ref),
    do: where(queryable, [episode_work_turns: t], t.turn_ref == ^turn_ref)

  @doc "Still running or stopped on a failure: pending, being cancelled or blocked."
  def unsettled(queryable) do
    where(
      queryable,
      [episode_work_turns: t],
      t.status in [:pending, :cancel_pending, :blocked]
    )
  end

  def select_ids(queryable), do: select(queryable, [episode_work_turns: t], t.id)

  def select_episode_ids(queryable),
    do: select(queryable, [episode_work_turns: t], t.episode_id)

  def by_ids(queryable \\ all(), ids), do: where(queryable, [episode_work_turns: t], t.id in ^ids)

  def select_sessions(queryable),
    do: select(queryable, [episode_work_turns: t], {t.id, t.session_id})

  @doc "An episode's latest settled turn that has a result."
  def latest_settled_with_result(episode_id) do
    from(t in all(),
      where: t.episode_id == ^episode_id and t.status == :settled and not is_nil(t.result_ref),
      order_by: [desc: t.accepted_at, desc: t.inserted_at, desc: t.id],
      limit: 1
    )
  end

  @doc "The turn `owner_ref` that owns `episode_id` and stopped on a failure."
  def blocked_owner(episode_id, owner_ref) do
    from(t in all(),
      where: t.episode_id == ^episode_id and t.turn_ref == ^owner_ref and t.status == :blocked,
      limit: 1
    )
  end

  @doc """
  Each of `episode_ids`' latest accepted turn that keeps its bodies, with what
  it delivered and why, as candidate outcomes show it.
  """
  def latest_accepted_outcomes(episode_ids) do
    from(t in all(),
      where: t.episode_id in ^episode_ids,
      where: not is_nil(t.accepted_at) and is_nil(t.operational_pruned_at),
      distinct: t.episode_id,
      order_by: [asc: t.episode_id, desc: t.accepted_at, desc: t.id],
      select: {t.episode_id, t.delivery_document, t.delivered_at, t.validation_intent}
    )
  end

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
