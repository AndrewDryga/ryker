defmodule Ryker.Schedules.ScheduleOccurrence.Query do
  @moduledoc "Each time a schedule fired or was missed, for every read of `episode_schedule_occurrences`."
  use Ryker, :query
  alias Ryker.Episodes.Episode
  alias Ryker.Schedules.ScheduleOccurrence
  alias Ryker.Work.Turn

  def all, do: from(occurrences in ScheduleOccurrence, as: :episode_schedule_occurrences)

  def by_schedule_id(queryable \\ all(), schedule_id),
    do: where(queryable, [episode_schedule_occurrences: o], o.schedule_id == ^schedule_id)

  @doc "A schedule's dispatched runs whose request has not ended."
  def running(schedule_id) do
    schedule_id
    |> by_schedule_id()
    |> join(:inner, [episode_schedule_occurrences: o], e in Episode,
      on: e.id == o.child_episode_id,
      as: :episode_kernel_episodes
    )
    |> where(
      [episode_schedule_occurrences: o, episode_kernel_episodes: e],
      o.status == :dispatched and e.state not in [:complete, :cancelled]
    )
  end

  @doc """
  A schedule's latest `limit` runs, each with its episode's state and its
  latest Work turn, as an automation's page shows them.
  """
  def recent_runs(schedule_id, limit) do
    schedule_id
    |> by_schedule_id()
    |> join(:left, [episode_schedule_occurrences: o], e in Episode,
      on: e.id == o.child_episode_id,
      as: :episode_kernel_episodes
    )
    |> join(
      :left_lateral,
      [episode_schedule_occurrences: o],
      t in subquery(Turn.Query.latest_of_occurrence()),
      on: true,
      as: :latest_turns
    )
    |> order_by([episode_schedule_occurrences: o], desc: o.scheduled_for, desc: o.id)
    |> limit(^limit)
    |> select(
      [episode_schedule_occurrences: o, episode_kernel_episodes: e, latest_turns: t],
      %{
        "accepted_at" => t.accepted_at,
        "delivered_at" => t.delivered_at,
        "episode_id" => o.child_episode_id,
        "episode_state" => e.state,
        "event_ref" => o.event_ref,
        "failure_code" => t.failure_code,
        "failure_detail" => t.failure_detail,
        "finished_at" => t.finished_at,
        "missed_reason" => o.missed_reason,
        "outcome" => o.status,
        "run_ref" => o.ref,
        "scheduled_for" => o.scheduled_for,
        "started_at" => t.started_at,
        "trigger" => o.trigger,
        "turn_status" => t.turn_status,
        "work_attempt_count" => t.work_attempt_count
      }
    )
  end
end
