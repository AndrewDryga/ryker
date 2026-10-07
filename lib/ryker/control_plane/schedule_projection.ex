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

  alias Ryker.ControlPlane.{Activity, EpisodeProjection, RepositoryNames}
  alias Ryker.ControlPlane.{ScheduleDirectory, Search}
  alias Ryker.Operator.FailureDetail
  alias Ryker.Repo
  alias Ryker.Work.FailureCause

  @list_limit 100
  @detail_limit 200
  @statuses ~w(active paused completed expired deleted)a
  @views %{"current" => [:active, :paused], "past" => [:completed, :expired, :deleted]}

  @doc """
  The schedule directory: the current view (running, then paused) or the past
  one (newest first), filtered by status and search. One row past
  #{@list_limit}, so the page can say when there are more than it shows.
  """
  def list(params) when is_map(params) do
    query =
      (@list_limit + 1)
      |> ScheduleDirectory.Query.directory()
      |> schedule_view(Map.get(@views, params["view"]))
      |> schedule_status(Search.one_of(params["status"], @statuses))
      |> schedule_search(Search.term(params["q"]))

    schedules = Repo.all(query)
    names = if Enum.any?(schedules, & &1.repository), do: RepositoryNames.all(), else: %{}
    Enum.map(schedules, &%{&1 | repository: RepositoryNames.name(names, &1.repository)})
  end

  def list(_params), do: list(%{})

  @doc "One schedule with its recorded occurrences, newest first."
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    query = ScheduleDirectory.Query.with_local_times(ref)

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
          repository:
            schedule.repository &&
              RepositoryNames.name(RepositoryNames.all(), schedule.repository),
          revision: schedule.revision,
          source_episode_id: schedule.source_episode_id,
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
    schedule
    |> ScheduleDirectory.Query.occurrences(@detail_limit + 1)
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

  defp schedule_view(query, statuses), do: ScheduleDirectory.Query.in_statuses(query, statuses)

  defp schedule_status(query, nil), do: query

  defp schedule_status(query, status), do: ScheduleDirectory.Query.with_status(query, status)

  defp schedule_search(query, nil), do: query

  defp schedule_search(query, search),
    do: ScheduleDirectory.Query.matching(query, Search.contains(search))

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
