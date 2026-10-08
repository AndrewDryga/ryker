defmodule Ryker.StateTools.CallRecord.Query do
  @moduledoc "Each state-tool call a Work turn made, for every read of `episode_work_state_tool_calls`."
  use Ryker, :query
  alias Ryker.StateTools.CallRecord
  alias Ryker.Work

  def all, do: from(calls in CallRecord, as: :episode_work_state_tool_calls)

  @doc "The latest `limit` calls an episode's turns made while the turns keep their bodies, newest first."
  def latest_by_episode_id(episode_id, limit) do
    all()
    |> join(:inner, [episode_work_state_tool_calls: c], t in Work.Turn,
      on: t.id == c.turn_id,
      as: :episode_work_turns
    )
    |> where(
      [episode_work_turns: t],
      t.episode_id == ^episode_id and is_nil(t.operational_pruned_at)
    )
    |> order_by([episode_work_state_tool_calls: c], desc: c.called_at, desc: c.id)
    |> limit(^limit)
  end

  def called_since(queryable, since),
    do: where(queryable, [episode_work_state_tool_calls: c], c.called_at >= ^since)
end
