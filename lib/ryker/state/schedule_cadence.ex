defmodule Ryker.State.ScheduleCadence do
  @moduledoc """
  How often a schedule runs, in words and in its own time zone: "Every day at
  09:00 Berlin time", "Every weekday at 09:00 UTC", "Once on 25 Sep at 09:00
  UTC", "Every 15 minutes".

  Every surface that states a cadence reads the stored recurrence through this
  one function — the schedules page, the Chat card, the Slack offer and saved
  schedule, and the GitHub comment — and never a title or task the model wrote.
  A card titled "weekday" once offered, and on confirmation created, a
  Monday-only schedule, because its only cadence line was the model's own.
  """

  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  @doc """
  The words for `recurrence` in `timezone`.

  A single run names its local time when the caller passes it as `once_local`
  (a database conversion), and its UTC time otherwise. `now_local` drops the
  year from a date in the current one.
  """
  @spec describe(map(), String.t() | nil, keyword()) :: String.t()
  def describe(recurrence, timezone, options \\ [])

  def describe(%{"kind" => "once", "at" => at}, timezone, options) do
    {local, zone} =
      case Keyword.get(options, :once_local) do
        %NaiveDateTime{} = local -> {local, zone(timezone)}
        nil -> {utc_naive(at), "UTC"}
      end

    if local,
      do: "Once on #{day(local, Keyword.get(options, :now_local))} at #{clock(local)} #{zone}",
      else: "Once"
  end

  def describe(%{"kind" => "interval", "every_seconds" => seconds}, _timezone, _options)
      when is_integer(seconds) and seconds > 0,
      do: "Every " <> period(seconds)

  def describe(%{"kind" => "daily", "time" => time}, timezone, _options),
    do: "Every day at #{clock_time(time)} #{zone(timezone)}"

  def describe(%{"kind" => "weekdays", "time" => time}, timezone, _options),
    do: "Every weekday at #{clock_time(time)} #{zone(timezone)}"

  def describe(%{"kind" => "weekly", "weekday" => day, "time" => time}, timezone, _options)
      when day in @weekdays,
      do: "Every #{String.capitalize(day)} at #{clock_time(time)} #{zone(timezone)}"

  def describe(%{"kind" => "monthly", "day" => day, "time" => time}, timezone, _options)
      when is_integer(day),
      do: "Every month on the #{ordinal(day)} at #{clock_time(time)} #{zone(timezone)}"

  def describe(_recurrence, _timezone, _options), do: "On a custom timing"

  defp period(seconds) do
    [{604_800, "week"}, {86_400, "day"}, {3_600, "hour"}, {60, "minute"}, {1, "second"}]
    |> Enum.find(fn {unit, _name} -> rem(seconds, unit) == 0 end)
    |> then(fn
      {^seconds, name} -> name
      {unit, name} -> "#{div(seconds, unit)} #{name}s"
    end)
  end

  defp ordinal(day) when day in [11, 12, 13], do: "#{day}th"

  defp ordinal(day) do
    case rem(day, 10) do
      1 -> "#{day}st"
      2 -> "#{day}nd"
      3 -> "#{day}rd"
      _ -> "#{day}th"
    end
  end

  # A saved "09:00:00" reads as 09:00; a time saved with seconds keeps them.
  defp clock_time(value) when is_binary(value) do
    case String.split(value, ":") do
      [hour, minute] -> hour <> ":" <> minute
      [hour, minute, "00"] -> hour <> ":" <> minute
      _other -> value
    end
  end

  defp clock_time(value), do: to_string(value)

  # The zone the way people say it: "Berlin time", "New York time", "UTC".
  defp zone(name) when name in ~w(UTC Etc/UTC Etc/UCT UCT Universal Etc/Universal Zulu Etc/Zulu),
    do: "UTC"

  defp zone(name) when name in ~w(GMT GMT0 Etc/GMT Etc/GMT0 Greenwich Etc/Greenwich), do: "UTC"

  defp zone(name) when is_binary(name) do
    place = name |> String.split("/") |> List.last()

    if Regex.match?(~r/\A(GMT|UTC)[+-]\d{1,2}\z|\A[A-Z0-9+-]{2,8}\z/, place),
      do: place,
      else: String.replace(place, "_", " ") <> " time"
  end

  defp zone(_name), do: "UTC"

  defp day(%NaiveDateTime{year: year} = local, %NaiveDateTime{year: year}),
    do: Calendar.strftime(local, "%-d %b")

  defp day(local, _now), do: Calendar.strftime(local, "%-d %b %Y")

  defp clock(local), do: Calendar.strftime(local, "%H:%M")

  defp utc_naive(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, utc, _offset} -> DateTime.to_naive(utc)
      _invalid -> nil
    end
  end

  defp utc_naive(_value), do: nil
end
