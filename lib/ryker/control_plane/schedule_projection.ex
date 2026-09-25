defmodule Ryker.ControlPlane.ScheduleProjection do
  @moduledoc """
  The schedule directory and one schedule's detail with its occurrences and
  the Work turn each occurrence ran, every failure body projected through
  `FailureDetail`.

  Times a person reads are converted to the schedule's own zone here, by the
  database, because the host carries no zone database of its own: the page
  words "every day at 09:00 Berlin time" and must show the next run in that
  same zone. `now_local` is the database's present in that zone, so "today"
  and "tomorrow" are the schedule's days, not the server's.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Activity, EpisodeProjection, Search}
  alias Ryker.Episodes.Episode
  alias Ryker.Operator.FailureDetail
  alias Ryker.Repo
  alias Ryker.State.{Schedule, ScheduleOccurrence}
  alias Ryker.Work.{FailureCause, Turn}

  @list_limit 100
  @detail_limit 200
  @statuses ~w(active paused completed expired deleted)a
  @views %{"current" => [:active, :paused], "past" => [:completed, :expired, :deleted]}

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
  The schedule directory: the current view (running, then paused) or the past
  one (newest first), filtered by status and search. At most #{@list_limit}
  rows; the page says so when it shows that many.
  """
  def list(params) when is_map(params) do
    query =
      from(schedule in Schedule,
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
        limit: @list_limit,
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
      |> schedule_view(Map.get(@views, params["view"]))
      |> schedule_status(Search.one_of(params["status"], @statuses))
      |> schedule_search(Search.term(params["q"]))

    Repo.all(query)
  end

  def list(_params), do: list(%{})

  @doc "One schedule with its recorded occurrences, newest first."
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    query =
      from(schedule in Schedule,
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

    case Repo.one(query) do
      nil -> :not_found
      {schedule, local} -> {:ok, detail(schedule, local)}
    end
  end

  def fetch(_ref), do: :not_found

  defp detail(schedule, local) do
    source_episode_ref = EpisodeProjection.key(schedule.source_episode_id)

    %{
      occurrences: occurrences(schedule),
      schedule:
        Map.merge(local, %{
          authority: schedule.authority,
          confirmed_at: schedule.confirmed_at,
          destination_conversation_ref: schedule.destination_conversation_ref,
          destination_thread_ref: schedule.destination_thread_ref,
          destination_transport: schedule.destination_transport,
          expires_at: schedule.expires_at,
          failure_count: schedule.failure_count,
          last_error: FailureDetail.project(schedule.last_error),
          next_occurrence_at: schedule.next_occurrence_at,
          recurrence: schedule.recurrence,
          ref: schedule.ref,
          repository: schedule.repository,
          revision: schedule.revision,
          source_episode_ref: source_episode_ref,
          source_request: source_request(source_episode_ref),
          status: schedule.status,
          task: schedule.task,
          timezone: schedule.timezone,
          title: schedule.title,
          updated_at: schedule.updated_at
        })
    }
  end

  defp occurrences(schedule) do
    latest_turns =
      from(turn in Turn,
        distinct: turn.episode_id,
        order_by: [asc: turn.episode_id, desc: turn.inserted_at, desc: turn.id],
        select: %{
          accepted_at: turn.accepted_at,
          delivered_at: turn.delivered_at,
          episode_id: turn.episode_id,
          last_error_code: turn.last_error_code,
          last_error_detail: turn.last_error_detail,
          remote_finished_at: turn.remote_finished_at,
          remote_started_at: turn.remote_started_at,
          status: turn.status,
          work_attempt_count: turn.work_attempt_count
        }
      )

    from(occurrence in ScheduleOccurrence,
      left_join: episode in Episode,
      on: episode.id == occurrence.child_episode_id,
      left_join: turn in subquery(latest_turns),
      on: turn.episode_id == occurrence.child_episode_id,
      where: occurrence.schedule_id == ^schedule.id,
      order_by: [desc: occurrence.scheduled_for, desc: occurrence.id],
      limit: @detail_limit,
      select: %{
        accepted_at: turn.accepted_at,
        delivered_at: turn.delivered_at,
        due_local: local(^schedule.timezone, occurrence.scheduled_for),
        episode_ref: episode.key,
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
    |> Repo.all()
    |> Enum.map(&sanitize_occurrence/1)
  end

  # The request the schedule was set up in, by the title Activity gives it.
  defp source_request(nil), do: nil

  defp source_request(ref) do
    case Activity.request_titles([ref]) do
      %{^ref => %{title: title, href: href}} -> %{title: title, href: href}
      _unavailable -> nil
    end
  end

  defp schedule_view(query, nil), do: query

  defp schedule_view(query, statuses),
    do: from(schedule in query, where: schedule.status in ^statuses)

  defp schedule_status(query, nil), do: query

  defp schedule_status(query, status),
    do: from(schedule in query, where: schedule.status == ^status)

  defp schedule_search(query, nil), do: query

  defp schedule_search(query, search) do
    pattern = Search.contains(search)

    from(schedule in query,
      where:
        ilike(schedule.ref, ^pattern) or ilike(schedule.title, ^pattern) or
          ilike(schedule.task, ^pattern) or ilike(schedule.repository, ^pattern) or
          ilike(schedule.destination_conversation_ref, ^pattern)
    )
  end

  # The saved error is an inspected internal term: the page gets the cause it
  # names in words, when it names one, and a digest for support otherwise.
  defp sanitize_occurrence(occurrence) do
    cause =
      case FailureCause.explain(occurrence.failure_detail) do
        %{cause: cause} -> cause
        nil -> nil
      end

    occurrence
    |> Map.put(:failure_cause, cause)
    |> Map.put(:failure_detail, FailureDetail.project(occurrence.failure_detail))
  end
end
