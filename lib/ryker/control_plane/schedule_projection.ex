defmodule Ryker.ControlPlane.ScheduleProjection do
  @moduledoc """
  The schedule directory and one schedule's detail with its occurrences and
  the Work turn each occurrence ran, every failure body projected through
  `FailureDetail`.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{EpisodeProjection, Search}
  alias Ryker.Episodes.Episode
  alias Ryker.Operator.FailureDetail
  alias Ryker.Repo
  alias Ryker.State.{Schedule, ScheduleOccurrence}
  alias Ryker.Work.Turn

  @list_limit 100
  @detail_limit 200
  @statuses ~w(active paused completed expired deleted)a

  @doc "The schedule directory, filtered by status and search."
  def list(params) when is_map(params) do
    query =
      from(schedule in Schedule,
        order_by: [asc: schedule.status, asc: schedule.next_occurrence_at, desc: schedule.id],
        limit: @list_limit,
        select: %{
          authority: schedule.authority,
          destination_conversation_ref: schedule.destination_conversation_ref,
          destination_transport: schedule.destination_transport,
          failures: schedule.failure_count,
          next_occurrence_at: schedule.next_occurrence_at,
          ref: schedule.ref,
          repository: schedule.repository,
          status: schedule.status,
          timezone: schedule.timezone,
          title: schedule.title,
          updated_at: schedule.updated_at
        }
      )
      |> schedule_status(Search.one_of(params["status"], @statuses))
      |> schedule_search(Search.term(params["q"]))

    Repo.all(query)
  end

  def list(_params), do: list(%{})

  @doc "One schedule with its recorded occurrences."
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(from(schedule in Schedule, where: schedule.ref == ^ref, limit: 1)) do
      nil ->
        :not_found

      schedule ->
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

        occurrences =
          Repo.all(
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
          )
          |> Enum.map(&sanitize_occurrence/1)

        {:ok,
         %{
           occurrences: occurrences,
           schedule: %{
             authority: schedule.authority,
             confirmed_at: schedule.confirmed_at,
             destination_conversation_ref: schedule.destination_conversation_ref,
             destination_thread_ref: schedule.destination_thread_ref,
             destination_transport: schedule.destination_transport,
             expires_at: schedule.expires_at,
             failure_count: schedule.failure_count,
             last_error: FailureDetail.project(schedule.last_error),
             next_occurrence_at: schedule.next_occurrence_at,
             recurrence: recurrence_label(schedule.recurrence),
             ref: schedule.ref,
             repository: schedule.repository,
             revision: schedule.revision,
             source_episode_ref: EpisodeProjection.key(schedule.source_episode_id),
             status: schedule.status,
             task: schedule.task,
             timezone: schedule.timezone,
             title: schedule.title,
             updated_at: schedule.updated_at
           }
         }}
    end
  end

  def fetch(_ref), do: :not_found

  defp schedule_status(query, nil), do: query

  defp schedule_status(query, status),
    do: from(schedule in query, where: schedule.status == ^status)

  defp schedule_search(query, nil), do: query

  defp schedule_search(query, search) do
    pattern = Search.contains(search)

    from(schedule in query,
      where:
        ilike(schedule.ref, ^pattern) or ilike(schedule.title, ^pattern) or
          ilike(schedule.repository, ^pattern) or
          ilike(schedule.destination_conversation_ref, ^pattern)
    )
  end

  defp sanitize_occurrence(occurrence) do
    Map.put(occurrence, :failure_detail, FailureDetail.project(occurrence.failure_detail))
  end

  defp recurrence_label(%{"kind" => "interval", "every_seconds" => seconds})
       when is_integer(seconds),
       do: "every #{seconds} seconds"

  defp recurrence_label(%{"kind" => "daily", "time" => time}), do: "daily at #{time}"

  defp recurrence_label(%{"kind" => "weekly", "weekday" => day, "time" => time}),
    do: "weekly on #{day} at #{time}"

  defp recurrence_label(%{"day" => day, "kind" => "monthly", "time" => time}),
    do: "monthly on day #{day} at #{time}"

  defp recurrence_label(%{"at" => at, "kind" => "once"}), do: "once at #{at}"
  defp recurrence_label(_unknown), do: "recorded recurrence"
end
