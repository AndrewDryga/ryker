defmodule Responder.State.ScheduleRecurrence do
  @moduledoc false

  alias Responder.Repo

  @weekdays %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7
  }

  @spec prepare_shape(map()) :: {:ok, map()} | {:error, term()}
  def prepare_shape(%{"at" => at, "kind" => "once"} = recurrence)
      when map_size(recurrence) == 2 do
    with {:ok, datetime} <- datetime(at) do
      {:ok, %{"at" => DateTime.to_iso8601(datetime), "kind" => "once"}}
    end
  end

  def prepare_shape(
        %{"every_seconds" => seconds, "kind" => "interval", "starts_at" => starts_at} =
          recurrence
      )
      when map_size(recurrence) == 3 and is_integer(seconds) and
             seconds in 300..31_536_000 do
    with {:ok, starts_at} <- optional_datetime(starts_at) do
      {:ok,
       %{
         "every_seconds" => seconds,
         "kind" => "interval",
         "starts_at" => starts_at && DateTime.to_iso8601(starts_at)
       }}
    end
  end

  def prepare_shape(%{"kind" => "daily", "time" => time} = recurrence)
      when map_size(recurrence) == 2 do
    with {:ok, time} <- time(time) do
      {:ok, %{"kind" => "daily", "time" => Time.to_iso8601(time)}}
    end
  end

  def prepare_shape(%{"kind" => "weekly", "time" => time, "weekday" => weekday} = recurrence)
      when map_size(recurrence) == 3 and is_map_key(@weekdays, weekday) do
    with {:ok, time} <- time(time) do
      {:ok, %{"kind" => "weekly", "time" => Time.to_iso8601(time), "weekday" => weekday}}
    end
  end

  def prepare_shape(%{"day" => day, "kind" => "monthly", "time" => time} = recurrence)
      when map_size(recurrence) == 3 and is_integer(day) and day in 1..31 do
    with {:ok, time} <- time(time) do
      {:ok, %{"day" => day, "kind" => "monthly", "time" => Time.to_iso8601(time)}}
    end
  end

  def prepare_shape(_recurrence),
    do: {:error, {:invalid_schedule, :recurrence}}

  @spec normalize(map(), String.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def normalize(recurrence, timezone, %DateTime{} = now) do
    with {:ok, recurrence} <- prepare_shape(recurrence),
         :ok <- timezone(timezone) do
      case recurrence do
        %{"kind" => "interval", "starts_at" => nil, "every_seconds" => seconds} ->
          {:ok,
           %{
             recurrence
             | "starts_at" => now |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
           }}

        recurrence ->
          {:ok, recurrence}
      end
    end
  end

  @spec next_after(map(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t() | nil} | {:error, term()}
  def next_after(%{"kind" => "once", "at" => at}, _timezone, after_datetime) do
    with {:ok, at} <- datetime(at) do
      if DateTime.compare(at, after_datetime) == :gt, do: {:ok, at}, else: {:ok, nil}
    end
  end

  def next_after(
        %{"every_seconds" => seconds, "kind" => "interval", "starts_at" => starts_at},
        _timezone,
        after_datetime
      ) do
    with {:ok, starts_at} <- datetime(starts_at) do
      if DateTime.compare(starts_at, after_datetime) == :gt do
        {:ok, starts_at}
      else
        elapsed = DateTime.diff(after_datetime, starts_at, :second)
        {:ok, DateTime.add(starts_at, (div(elapsed, seconds) + 1) * seconds, :second)}
      end
    end
  end

  def next_after(%{"kind" => kind} = recurrence, timezone, after_datetime)
      when kind in ["daily", "weekly", "monthly"] do
    with :ok <- timezone(timezone),
         {:ok, local_after} <- local_datetime(after_datetime, timezone) do
      local_candidate(recurrence, local_after, timezone, 0)
    end
  end

  def next_after(_recurrence, _timezone, _after_datetime),
    do: {:error, {:invalid_schedule, :recurrence}}

  defp local_candidate(_recurrence, _local_after, _timezone, attempts) when attempts > 370,
    do: {:error, {:invalid_schedule, :recurrence}}

  defp local_candidate(%{"kind" => "daily", "time" => time}, local_after, timezone, attempts) do
    {:ok, time} = time(time)
    date = NaiveDateTime.to_date(local_after) |> Date.add(attempts)

    choose_local(
      date,
      time,
      local_after,
      timezone,
      attempts,
      &local_candidate(%{"kind" => "daily", "time" => Time.to_iso8601(time)}, &1, timezone, &2)
    )
  end

  defp local_candidate(
         %{"kind" => "weekly", "time" => time, "weekday" => weekday} = recurrence,
         local_after,
         timezone,
         attempts
       ) do
    {:ok, time} = time(time)
    current = Date.day_of_week(NaiveDateTime.to_date(local_after))
    wanted = Map.fetch!(@weekdays, weekday)
    base_days = rem(wanted - current + 7, 7)
    date = NaiveDateTime.to_date(local_after) |> Date.add(base_days + attempts * 7)

    choose_local(
      date,
      time,
      local_after,
      timezone,
      attempts,
      &local_candidate(recurrence, &1, timezone, &2)
    )
  end

  defp local_candidate(
         %{"day" => day, "kind" => "monthly", "time" => time} = recurrence,
         local_after,
         timezone,
         attempts
       ) do
    {:ok, time} = time(time)
    date = NaiveDateTime.to_date(local_after)
    {year, month} = add_months(date.year, date.month, attempts)

    if day <= Calendar.ISO.days_in_month(year, month) do
      {:ok, candidate_date} = Date.new(year, month, day)

      choose_local(
        candidate_date,
        time,
        local_after,
        timezone,
        attempts,
        &local_candidate(recurrence, &1, timezone, &2)
      )
    else
      local_candidate(recurrence, local_after, timezone, attempts + 1)
    end
  end

  defp choose_local(date, time, local_after, timezone, attempts, retry) do
    {:ok, naive} = NaiveDateTime.new(date, time)

    if NaiveDateTime.compare(naive, local_after) == :gt do
      local_to_utc(naive, timezone)
    else
      retry.(local_after, attempts + 1)
    end
  end

  defp add_months(year, month, count) do
    zero_based = year * 12 + month - 1 + count
    {div(zero_based, 12), rem(zero_based, 12) + 1}
  end

  defp timezone(value) when is_binary(value) and byte_size(value) in 1..128 do
    case Repo.query("SELECT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name = $1)", [value]) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, {:invalid_schedule, :timezone}}
      {:error, reason} -> {:error, {:schedule_timezone_lookup_failed, reason}}
    end
  end

  defp timezone(_value), do: {:error, {:invalid_schedule, :timezone}}

  defp local_datetime(datetime, timezone) do
    case Repo.query("SELECT timezone($2, $1::timestamptz)", [datetime, timezone]) do
      {:ok, %{rows: [[%NaiveDateTime{} = local]]}} -> {:ok, local}
      {:error, reason} -> {:error, {:schedule_timezone_conversion_failed, reason}}
    end
  end

  defp local_to_utc(naive, timezone) do
    case Repo.query("SELECT $1::timestamp AT TIME ZONE $2", [naive, timezone]) do
      {:ok, %{rows: [[%DateTime{} = utc]]}} -> {:ok, utc}
      {:error, reason} -> {:error, {:schedule_timezone_conversion_failed, reason}}
    end
  end

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(value), do: datetime(value)

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_schedule, :recurrence}}
    end
  end

  defp datetime(_value), do: {:error, {:invalid_schedule, :recurrence}}

  defp time(<<_hour::binary-size(2), ":", _minute::binary-size(2)>> = value),
    do: time(value <> ":00")

  defp time(value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      _invalid -> {:error, {:invalid_schedule, :recurrence}}
    end
  end

  defp time(_value), do: {:error, {:invalid_schedule, :recurrence}}
end
