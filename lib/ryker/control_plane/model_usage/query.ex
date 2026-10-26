defmodule Ryker.ControlPlane.ModelUsage.Query do
  @moduledoc "Recent measured model turns, grouped by the policy that actually ran them."
  use Ryker, :query
  alias Ryker.Accounting
  alias Ryker.Work

  def recent(now) do
    month = DateTime.add(now, -30, :day)
    week = DateTime.add(now, -7, :day)

    Accounting.Execution.Query.all()
    |> join(:left, [execution_usage: e], s in Work.Session,
      as: :episode_work_sessions,
      on: s.id == e.session_id
    )
    |> where([execution_usage: e], e.execution_mode == "live" and e.usage_recorded)
    |> where(
      [execution_usage: e],
      fragment("COALESCE(?, ?)", e.remote_started_at, e.recorded_at) >= ^month and
        fragment("COALESCE(?, ?)", e.remote_started_at, e.recorded_at) <= ^now
    )
    |> group_by([execution_usage: e, episode_work_sessions: s], [e.kind, s.policy])
    |> select([execution_usage: e, episode_work_sessions: s], %{
      kind: e.kind,
      policy: s.policy,
      week:
        fragment(
          "COUNT(*) FILTER (WHERE COALESCE(?, ?) >= ?)",
          e.remote_started_at,
          e.recorded_at,
          type(^week, :utc_datetime_usec)
        ),
      month: count(e.id),
      last_used_at:
        type(
          max(fragment("COALESCE(?, ?)", e.remote_started_at, e.recorded_at)),
          :utc_datetime_usec
        )
    })
  end
end
