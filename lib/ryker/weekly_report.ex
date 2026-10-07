defmodule Ryker.WeeklyReport do
  @moduledoc """
  The weekly report: one message a week in the Slack channel Settings ›
  Weekly report names, at the day and local time it names, saying how
  Ryker's week went the way a teammate writes a weekly update in Slack. Off
  until a person turns it on.

  **What it says.** The PRs Ryker opened that week and the ones already
  merged, every PR still waiting for review, how many messages it handled,
  how long a typical reply took and how many were quick answers, the
  questions it is waiting on people to answer, anything stuck, and a closing
  line on how people took its answers, what it learned and what the week's
  work cost (an estimate at API prices when the provider reported no price)
  (`Ryker.WeeklyReport.Digest`). It names no Slack request it merely
  answered and gives no completion rate.

  **How it is made.** From the database alone, with no model turn
  (`Ryker.WeeklyReport.Facts`, `Ryker.WeeklyReport.Digest`), so it cannot say
  anything the tables do not hold. The worst it can do is count the wrong
  rows, and that is a bug a test can catch.

  **Its week.** A report covers the seven days before it is sent: from the
  same day and local time a week earlier up to the send time
  (`Ryker.WeeklyReport.Schedule`), so each week's report starts where the
  last one ended. A preview covers the seven days before now.

  **When it is sent.** At most once per calendar week (Monday to Sunday in
  the report's zone), and never for a send time that passed before the
  settings were last saved: turning it on does not post at once, it posts at
  the next send time. A send Ryker was down for is posted when it is back, if
  it is still the latest one; a longer outage posts one report, not one for
  every week missed. The week's row (`Ryker.WeeklyReport.Report`) is written
  when the report falls due, so a restart never posts a week twice, and it is
  the post's delivery custody (`Ryker.WeeklyReport.Custody`): retries, and a
  refusal on Failures, like every other post.

  **A preview.** Settings › Weekly report shows what a report sent now would
  say (`preview/1`), and can send it to the chosen channel now
  (`send_preview/1`), titled as a preview. A preview goes through the same
  custody as the week's report and is not the week's report: the scheduled
  one still posts.
  """

  alias Ryker.Config
  alias Ryker.Repo
  alias Ryker.Settings.{Report, Slack}
  alias Ryker.WeeklyReport.{Custody, Digest, Facts, Schedule}

  @week_seconds 7 * 86_400

  @doc """
  The report for `week` (`from`, `to` and its `timezone`), read at `:now`.
  Options: `:now`, `:base_url` for the links (the console's address by
  default), `:time_zone_database` and `:preview`, which titles it as one.
  """
  @spec compose(map(), keyword()) :: Digest.t()
  def compose(week, options \\ []) do
    now = Keyword.get_lazy(options, :now, &DateTime.utc_now/0)

    week
    |> Facts.read(now)
    |> Digest.render(
      base_url: Keyword.get_lazy(options, :base_url, &base_url/0),
      time_zone_database: database(options),
      preview: Keyword.get(options, :preview, false)
    )
  end

  @doc """
  What a report sent now would say: the seven days before now, in the saved
  report's time zone. Nothing is posted or recorded.
  """
  @spec preview(keyword()) :: Digest.t()
  def preview(options \\ []) do
    # Messages are stamped by the database's clock, so the week ends by it too: a
    # host clock behind the database's left out a message answered a moment earlier.
    now = Keyword.get_lazy(options, :now, &Repo.now!/0)

    zone =
      case Repo.one(Report.Query.select_timezone()) do
        zone when is_binary(zone) -> zone
        nil -> "Etc/UTC"
      end

    compose(last_seven_days(now, zone), Keyword.put(options, :now, now))
  end

  @doc """
  Sends a preview to the chosen channel now: the seven days before now,
  titled as a preview, queued for delivery like the week's report and never
  counted as it. The report need not be on; it needs a channel and Slack
  connected, and says `{:error, :no_channel}` otherwise.
  """
  @spec send_preview(keyword()) :: {:ok, map()} | {:error, term()}
  def send_preview(options \\ []) do
    now = Keyword.get_lazy(options, :now, &Repo.now!/0)
    database = database(options)

    with {:ok, configured} <- destination(),
         zone = configured.schedule.timezone,
         {:ok, local} <- DateTime.shift_zone(now, zone, database) do
      week = last_seven_days(now, zone)

      digest =
        compose(
          week,
          Keyword.merge(options, now: now, time_zone_database: database, preview: true)
        )

      Custody.enqueue(%{
        conversation_ref: configured.conversation_ref,
        due_at: now,
        message: digest.text,
        period_start: week.from,
        preview: true,
        timezone: zone,
        week: local |> DateTime.to_date() |> Date.beginning_of_week()
      })
    end
  end

  defp last_seven_days(now, zone),
    do: %{from: DateTime.add(now, -@week_seconds, :second), to: now, timezone: zone}

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
    case destination() do
      {:ok, %{enabled: true} = configured} -> {:ok, configured}
      _off -> :off
    end
  end

  # Where the report goes, on or not: its channel, while Slack is connected
  # to a workspace.
  defp destination do
    with %Report{channel_ref: channel} = report when is_binary(channel) <-
           Repo.one(Report.Query.all()),
         %{enabled: true, workspace_ref: workspace} when is_binary(workspace) <-
           Repo.one(Slack.Query.select_connection()) do
      {:ok,
       %{
         conversation_ref: "slack:#{workspace}:#{channel}",
         enabled: report.weekly_self_report_enabled,
         saved_at: report.saved_at,
         schedule: %{
           weekday: report.weekday,
           local_time: report.local_time,
           timezone: report.timezone
         }
       }}
    else
      _none -> {:error, :no_channel}
    end
  end

  defp due(%{schedule: schedule} = configured, now, database, options) do
    with {:ok, latest} <- Schedule.latest(schedule, now, database),
         {:ok, next} <- Schedule.next(schedule, now, database) do
      if Custody.recorded?(latest.week) or not after_last_save?(latest.at, configured.saved_at) do
        {:ok, {:waiting, next.at}}
      else
        queue(latest, configured, now, database, options, next)
      end
    end
  end

  defp queue(latest, configured, now, database, options, next) do
    with {:ok, previous} <- Schedule.previous(latest, configured.schedule, database) do
      digest =
        compose(
          %{from: previous.at, to: latest.at, timezone: configured.schedule.timezone},
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
  # moving its day, never posts at once.
  defp after_last_save?(_at, nil), do: true
  defp after_last_save?(at, saved_at), do: DateTime.after?(at, saved_at)

  @doc "The console's address the report's links start with."
  @spec base_url() :: String.t()
  def base_url, do: Config.get_env(:control_public_url, "http://127.0.0.1:4321")

  defp database(options),
    do: Keyword.get_lazy(options, :time_zone_database, &Calendar.get_time_zone_database/0)
end
