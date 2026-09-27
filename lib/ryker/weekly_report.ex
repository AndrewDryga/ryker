defmodule Ryker.WeeklyReport do
  @moduledoc """
  The weekly report: one message a week in the Slack channel Settings ›
  Weekly report names, at the day and local time it names, saying how
  Ryker's week went. Off until a person turns it on.

  **What it says.** Requests (the messages Ryker read and what became of
  them, and the requests it took on and where each stands), Feedback
  (positive and negative, by kind, and the requests people were frustrated
  with), What to fix (what self-analysis found and what people decided, and
  the newest diagnosis Ryker was sure of), Corrections (how often routing's
  and Work's answers needed correcting, and the correction given most
  often), Learned (new facts and topics, and the newest), Needs a person (the
  failures open now that leave someone without a reply, an update or a
  result) and Cost (what the week's model calls cost). Each number stands
  beside last week's where the two compare, each section links to the page
  that holds the rest, and a section with nothing to say says None.

  **How it is made.** From the database alone, with no model turn
  (`Ryker.WeeklyReport.Facts`, `Ryker.WeeklyReport.Digest`), so it cannot say
  anything the tables do not hold. The worst it can do is count the wrong
  rows, and that is a bug a test can catch.

  **Its week.** A report covers the seven days before it is sent: from the
  same day and local time a week earlier up to the send time
  (`Ryker.WeeklyReport.Schedule`), so each week's report starts where the
  last one ended. The preview on the settings page covers the seven days
  before now.

  **When it is sent.** At most once per calendar week (Monday to Sunday in
  the report's zone), and never for a send time that passed before the
  settings were last saved: turning it on does not post at once, it posts at
  the next send time. A send Ryker was down for is posted when it is back, if
  it is still the latest one; a longer outage posts one report, not one for
  every week missed. The week's row (`Ryker.WeeklyReport.Report`) is written
  when the report falls due, so a restart never posts a week twice, and it is
  the post's delivery custody (`Ryker.WeeklyReport.Custody`): retries, and a
  refusal on Failures, like every other post.
  """

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.Settings.{Edit, Report, Slack}
  alias Ryker.WeeklyReport.{Custody, Digest, Facts, Schedule}

  @week_seconds 7 * 86_400

  @doc """
  The report for `week` (`from`, `to`, `previous_from` and its `timezone`),
  read at `:now`. Options: `:now`, `:base_url` for the links (the console's
  address by default) and `:time_zone_database`.
  """
  @spec compose(map(), keyword()) :: Digest.t()
  def compose(week, options \\ []) do
    now = Keyword.get_lazy(options, :now, &DateTime.utc_now/0)

    week
    |> Facts.read(now)
    |> Digest.render(
      base_url: Keyword.get_lazy(options, :base_url, &base_url/0),
      time_zone_database: database(options)
    )
  end

  @doc """
  What a report sent now would say: the seven days before now, in the saved
  report's time zone. Nothing is posted or recorded.
  """
  @spec preview(keyword()) :: Digest.t()
  def preview(options \\ []) do
    now = Keyword.get_lazy(options, :now, &DateTime.utc_now/0)

    zone =
      case Repo.one(from(report in Report, select: report.timezone)) do
        zone when is_binary(zone) -> zone
        nil -> "Etc/UTC"
      end

    compose(
      %{
        from: DateTime.add(now, -@week_seconds, :second),
        to: now,
        previous_from: DateTime.add(now, -2 * @week_seconds, :second),
        timezone: zone
      },
      Keyword.put(options, :now, now)
    )
  end

  @doc """
  One pass of the schedule at `:now`: when the latest send time has come and
  its week has no report yet, and it came after the settings were last
  saved, the week's report is composed and queued for delivery.

  Returns `{:ok, :off}` while the report is off, has no channel or Slack is
  not connected, touching nothing; otherwise `{:ok, {:queued, report,
  next_at}}` or `{:ok, {:waiting, next_at}}`, `next_at` being the next send
  time.
  """
  @spec run_once(keyword()) ::
          {:ok, :off | {:waiting, DateTime.t()} | {:queued, map(), DateTime.t()}}
          | {:error, term()}
  def run_once(options \\ []) do
    now = Keyword.get_lazy(options, :now, &DateTime.utc_now/0)
    database = database(options)

    case configured() do
      {:ok, configured} -> due(configured, now, database, options)
      :off -> {:ok, :off}
    end
  end

  # The saved report, when it can be sent: on, with a channel, and Slack
  # connected to a workspace.
  defp configured do
    with %Report{weekly_self_report_enabled: true, channel_ref: channel} = report
         when is_binary(channel) <- Repo.one(Report),
         %{enabled: true, workspace_ref: workspace} when is_binary(workspace) <-
           Repo.one(from(slack in Slack, select: map(slack, [:enabled, :workspace_ref]))) do
      {:ok,
       %{
         conversation_ref: "slack:#{workspace}:#{channel}",
         schedule: %{
           weekday: report.weekday,
           local_time: report.local_time,
           timezone: report.timezone
         }
       }}
    else
      _off -> :off
    end
  end

  defp due(%{schedule: schedule} = configured, now, database, options) do
    with {:ok, latest} <- Schedule.latest(schedule, now, database),
         {:ok, next} <- Schedule.next(schedule, now, database) do
      if Custody.recorded?(latest.week) or not after_last_save?(latest.at) do
        {:ok, {:waiting, next.at}}
      else
        queue(latest, configured, now, database, options, next)
      end
    end
  end

  defp queue(latest, configured, now, database, options, next) do
    with {:ok, previous} <- Schedule.previous(latest, configured.schedule, database),
         {:ok, before} <- Schedule.previous(previous, configured.schedule, database) do
      digest =
        compose(
          %{
            from: previous.at,
            to: latest.at,
            previous_from: before.at,
            timezone: configured.schedule.timezone
          },
          Keyword.merge(options, now: now, time_zone_database: database)
        )

      case Custody.enqueue(%{
             conversation_ref: configured.conversation_ref,
             due_at: latest.at,
             message: digest.text,
             period_start: previous.at,
             timezone: configured.schedule.timezone,
             week: latest.week
           }) do
        {:ok, :already_queued} -> {:ok, {:waiting, next.at}}
        {:ok, report} -> {:ok, {:queued, report, next.at}}
        {:error, _reason} = error -> error
      end
    end
  end

  # A send time that passed before the report settings were last saved
  # belongs to a schedule nobody had chosen yet: turning the report on, or
  # moving its day, never posts at once. With no save on record (the audit
  # horizon removed it) every send time counts.
  defp after_last_save?(at) do
    case Repo.one(
           from(edit in Edit, where: edit.domain == :report, select: max(edit.inserted_at))
         ) do
      nil -> true
      saved_at -> DateTime.after?(at, Ryker.UTCDateTime.earliest([saved_at]))
    end
  end

  @doc "The console's address the report's links start with."
  @spec base_url() :: String.t()
  def base_url, do: Application.get_env(:ryker, :control_public_url, "http://127.0.0.1:4321")

  defp database(options),
    do: Keyword.get_lazy(options, :time_zone_database, &Calendar.get_time_zone_database/0)
end
