defmodule Ryker.Work.ActivityEventQuery do
  @moduledoc "What a Work worker reported doing, for every read of `episode_work_activity`."
  import Ecto.Query
  alias Ryker.Work.ActivityEvent

  def all, do: from(events in ActivityEvent, as: :episode_work_activity)

  @doc "A Coop turn's events of `kinds` that keep their bodies, oldest first, as training reads them."
  def trajectory(episode_id, coop_turn_id, kinds) do
    all()
    |> where(
      [episode_work_activity: a],
      a.episode_id == ^episode_id and a.coop_turn_id == ^coop_turn_id and a.kind in ^kinds and
        is_nil(a.operational_pruned_at)
    )
    |> order_by([episode_work_activity: a], asc: a.sequence, asc: a.occurred_at)
    |> select([episode_work_activity: a], %{
      "kind" => a.kind,
      "at" => a.occurred_at,
      "payload" => a.payload
    })
  end

  @doc """
  The tool calls of episode `episode_id` that keep their bodies, started and
  completed, in order, as `{coop_turn_id, kind, payload}`.
  """
  def tool_events(episode_id) do
    from(a in all(),
      where:
        a.episode_id == ^episode_id and a.kind in ["tool.started", "tool.completed"] and
          is_nil(a.operational_pruned_at),
      order_by: [asc: a.occurred_at, asc: a.sequence],
      select: {a.coop_turn_id, a.kind, a.payload}
    )
  end
end
