defmodule Ryker.ControlPlane.ScheduleDirectory.Query do
  @moduledoc """
  What the Schedules pages read (`Ryker.ControlPlane.ScheduleProjection`):
  the directory in its order, view, status filter and search, one schedule
  with its times in its own zone, and its runs beside each run's latest turn.
  """
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Schedules
  alias Ryker.Work

  # A stored UTC instant as the wall-clock time in `zone`.
  defmacrop local(zone, at) do
    quote do
      fragment("timezone(?, ? AT TIME ZONE 'UTC')", unquote(zone), unquote(at))
    end
  end

  # A one-time schedule's saved moment, in its zone; nothing for the others.
  defmacrop once_local(zone, recurrence) do
    quote do
      fragment(
        "CASE WHEN ?::jsonb ->> 'kind' = 'once' THEN timezone(?, (?::jsonb ->> 'at')::timestamptz) END",
        unquote(recurrence),
        unquote(zone),
        unquote(recurrence)
      )
    end
  end

  @doc """
  The first `limit` schedules in the directory's order (running, then
  paused, then the rest; soonest due first; newest), as its rows.
  """
  def directory(limit) do
    from([episode_schedules: schedule] in Schedules.Schedule.Query.all(),
      order_by: [
        asc:
          fragment(
            "CASE ? WHEN 'active' THEN 0 WHEN 'paused' THEN 1 ELSE 2 END",
            schedule.status
          ),
        asc_nulls_last:
          fragment(
            "CASE WHEN ? = 'active' THEN ? END",
            schedule.status,
            schedule.next_occurrence_at
          ),
        desc: schedule.updated_at,
        desc: schedule.id
      ],
      limit: ^limit,
      select: %{
        authority: schedule.authority,
        destination_conversation_ref: schedule.destination_conversation_ref,
        destination_thread_ref: schedule.destination_thread_ref,
        destination_transport: schedule.destination_transport,
        expires_at: schedule.expires_at,
        expires_local: local(schedule.timezone, schedule.expires_at),
        failures: schedule.failure_count,
        next_local: local(schedule.timezone, schedule.next_occurrence_at),
        next_occurrence_at: schedule.next_occurrence_at,
        now_local: fragment("timezone(?, now())", schedule.timezone),
        once_local: once_local(schedule.timezone, schedule.recurrence),
        recurrence: schedule.recurrence,
        ref: schedule.ref,
        repository: schedule.repository,
        status: schedule.status,
        task: schedule.task,
        timezone: schedule.timezone,
        title: schedule.title,
        updated_at: schedule.updated_at
      }
    )
  end

  @doc "The schedules whose ref, title, task, repository or conversation contains `pattern`."
  def matching(queryable, pattern) do
    where(
      queryable,
      [episode_schedules: s],
      ilike(s.ref, ^pattern) or ilike(s.title, ^pattern) or ilike(s.task, ^pattern) or
        ilike(s.repository, ^pattern) or ilike(s.destination_conversation_ref, ^pattern)
    )
  end

  @doc "Schedule `ref` with its times in its own zone, as `{schedule, local_times}`."
  def by_ref_with_local_times(ref) do
    from(schedule in Schedules.Schedule,
      where: schedule.ref == ^ref,
      limit: 1,
      select:
        {schedule,
         %{
           expires_local: local(schedule.timezone, schedule.expires_at),
           next_local: local(schedule.timezone, schedule.next_occurrence_at),
           now_local: fragment("timezone(?, now())", schedule.timezone),
           once_local: once_local(schedule.timezone, schedule.recurrence)
         }}
    )
  end

  @doc """
  The first `limit` runs of `schedule`, newest first, each beside its latest
  turn, read for that run's episode alone: ranking every turn in the database
  read the whole table to show ten runs (2026-10-04 review).
  """
  def occurrences(schedule, limit) do
    latest_turn =
      from(turn in Work.Turn,
        where: turn.episode_id == parent_as(:occurrence).child_episode_id,
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 1,
        select: %{
          accepted_at: turn.accepted_at,
          delivered_at: turn.delivered_at,
          last_error_code: turn.last_error_code,
          last_error_detail: turn.last_error_detail,
          remote_finished_at: turn.remote_finished_at,
          remote_started_at: turn.remote_started_at,
          status: turn.status,
          work_attempt_count: turn.work_attempt_count
        }
      )

    from(occurrence in Schedules.ScheduleOccurrence,
      as: :occurrence,
      left_join: episode in Episodes.Episode,
      on: episode.id == occurrence.child_episode_id,
      left_lateral_join: turn in subquery(latest_turn),
      on: true,
      where: occurrence.schedule_id == ^schedule.id,
      order_by: [desc: occurrence.scheduled_for, desc: occurrence.id],
      limit: ^limit,
      select: %{
        accepted_at: turn.accepted_at,
        delivered_at: turn.delivered_at,
        due_local: local(^schedule.timezone, occurrence.scheduled_for),
        episode_id: episode.id,
        episode_state: episode.state,
        failure_code: turn.last_error_code,
        failure_detail: turn.last_error_detail,
        finished_at: turn.remote_finished_at,
        missed_reason: occurrence.missed_reason,
        ref: occurrence.ref,
        scheduled_for: occurrence.scheduled_for,
        started_at: turn.remote_started_at,
        status: occurrence.status,
        trigger: occurrence.trigger,
        turn_status: turn.status,
        work_attempt_count: turn.work_attempt_count
      }
    )
  end
end
