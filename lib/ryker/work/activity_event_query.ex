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
end
