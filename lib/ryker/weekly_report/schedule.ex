defmodule Ryker.WeeklyReport.Schedule do
  @moduledoc """
  When the weekly report is sent, and which week each send is.

  The settings name a day of the week (1 is Monday, 7 is Sunday), a local
  time and a time zone. An occurrence is that day and local time in one
  calendar week, Monday to Sunday in that zone; the report sent at it covers
  the seven days before it, from the previous occurrence up to it, so one
  week's report ends exactly where the next one starts.

  A clock change is read the way a person reads it: a local time the spring
  change skips is sent the moment the clock jumps past it, and one the autumn
  change repeats is sent the first time it comes round.

  Everything here is arithmetic on its arguments. The time zone database is
  an argument too: the release reads the IANA zones (`Tz`), and tests hand in
  one whose clock changes they choose.
  """

  @type schedule :: %{weekday: 1..7, local_time: Time.t(), timezone: String.t()}
  @type occurrence :: %{at: DateTime.t(), date: Date.t(), week: Date.t()}

  @doc """
  The latest occurrence at or before `now`, with the local `date` it falls on
  and the `week` it belongs to (that week's Monday).
  """
  @spec latest(schedule(), DateTime.t(), module()) :: {:ok, occurrence()} | {:error, term()}
  def latest(schedule, %DateTime{} = now, database) do
    with {:ok, date} <- this_week(schedule, now, database),
         {:ok, candidate} <- on(date, schedule, database) do
      if DateTime.after?(candidate.at, now),
        do: on(Date.add(date, -7), schedule, database),
        else: {:ok, candidate}
    end
  end

  @doc "The first occurrence after `now`."
  @spec next(schedule(), DateTime.t(), module()) :: {:ok, occurrence()} | {:error, term()}
  def next(schedule, %DateTime{} = now, database) do
    with {:ok, date} <- this_week(schedule, now, database),
         {:ok, candidate} <- on(date, schedule, database) do
      if DateTime.after?(candidate.at, now),
        do: {:ok, candidate},
        else: on(Date.add(date, 7), schedule, database)
    end
  end

  @doc "The occurrence a week before `occurrence`: where its report's week starts."
  @spec previous(occurrence(), schedule(), module()) :: {:ok, occurrence()} | {:error, term()}
  def previous(%{date: date}, schedule, database), do: on(Date.add(date, -7), schedule, database)

  # The configured day in the calendar week `now` falls in, in the zone.
  defp this_week(schedule, now, database) do
    with {:ok, local} <- DateTime.shift_zone(now, schedule.timezone, database) do
      {:ok,
       local
       |> DateTime.to_date()
       |> Date.beginning_of_week()
       |> Date.add(schedule.weekday - 1)}
    end
  end

  defp on(date, schedule, database) do
    with {:ok, at} <- moment(date, schedule.local_time, schedule.timezone, database) do
      {:ok, %{at: at, date: date, week: Date.beginning_of_week(date)}}
    end
  end

  defp moment(date, time, zone, database) do
    case DateTime.new(date, time, zone, database) do
      {:ok, at} -> {:ok, utc(at)}
      {:ambiguous, first, _second} -> {:ok, utc(first)}
      {:gap, _before, just_after} -> {:ok, utc(just_after)}
      {:error, _reason} = error -> error
    end
  end

  # Whole seconds at the precision every timestamp column keeps.
  defp utc(moment) do
    utc = moment |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
    %{utc | microsecond: {0, 6}}
  end
end
