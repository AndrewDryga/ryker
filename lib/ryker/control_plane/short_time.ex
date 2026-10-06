defmodule Ryker.ControlPlane.ShortTime do
  @moduledoc """
  Times the way people say them: "just now", "2 h ago", "yesterday",
  "12 Sep", "tomorrow 09:00 UTC". The exact UTC instant stays one hover away,
  in the `<time>` element's `datetime` and `title`.

  Every time is read in UTC, the zone the rest of the workspace shows, so a
  short time and the full one beside it never disagree about the day.
  """
  use Phoenix.Component

  attr(:at, :any, required: true, doc: "A DateTime, NaiveDateTime or ISO-8601 string")
  attr(:now, :any, default: nil, doc: "The moment the page is read; defaults to now")
  attr(:prefix, :string, default: nil, doc: "Words before the time, e.g. \"updated \"")

  @doc "A short time with its exact UTC instant in `datetime` and `title`."
  def time(assigns) do
    assigns =
      assigns
      |> assign_new(:now, fn -> nil end)
      |> assign_new(:prefix, fn -> nil end)
      |> then(&assign(&1, :at, utc(&1.at)))

    ~H"""
    <time
      :if={@at}
      datetime={DateTime.to_iso8601(@at)}
      title={full(@at)}
    >{@prefix}{text(@at, @now || DateTime.utc_now())}</time>
    """
  end

  @doc "The short words for `at`, read at `now`; nil when there is no time."
  @spec text(term(), DateTime.t()) :: String.t() | nil
  def text(at, %DateTime{} = now) do
    case utc(at) do
      nil -> nil
      at -> words(at, DateTime.diff(now, at), DateTime.to_date(at), DateTime.to_date(now))
    end
  end

  @doc "The exact instant, e.g. \"12 Sep 2026, 09:00 UTC\"."
  @spec full(DateTime.t()) :: String.t()
  def full(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y, %H:%M UTC")

  @doc """
  A day as every page writes one: "5 Oct", or "5 Oct 2025" in another year
  than `today`'s. Each page had worked the year out its own way, and Chat's
  list and every "Saved" stamp left it out (2026-10-04 review).
  """
  @spec day(Date.t() | DateTime.t() | NaiveDateTime.t(), Date.t() | DateTime.t()) :: String.t()
  def day(at, today) do
    if at.year == today.year,
      do: Calendar.strftime(at, "%-d %b"),
      else: Calendar.strftime(at, "%-d %b %Y")
  end

  @doc ~s(A moment: "5 Oct, 09:30 UTC", with the year once it is not `now`'s.)
  @spec stamp(DateTime.t() | NaiveDateTime.t(), DateTime.t()) :: String.t()
  def stamp(at, now) do
    at = utc(at)
    day(at, now) <> ", " <> Calendar.strftime(at, "%H:%M UTC")
  end

  defp words(_at, seconds, _day, _today) when seconds in 0..59, do: "just now"

  defp words(_at, seconds, _day, _today) when seconds in 60..3_599,
    do: "#{div(seconds, 60)} min ago"

  defp words(_at, seconds, _day, _today) when seconds in 3_600..86_399,
    do: "#{div(seconds, 3_600)} h ago"

  defp words(at, seconds, day, today) when seconds >= 0 do
    if Date.diff(today, day) == 1, do: "yesterday", else: day(at, today)
  end

  defp words(_at, seconds, _day, _today) when seconds > -60, do: "in a moment"
  defp words(_at, seconds, _day, _today) when seconds > -3_600, do: "in #{div(-seconds, 60)} min"

  # A clock time to come names its zone; how long ago something was needs none.
  defp words(at, _seconds, day, today) do
    clock = Calendar.strftime(at, "%H:%M UTC")

    case Date.diff(day, today) do
      0 -> "today " <> clock
      1 -> "tomorrow " <> clock
      _later -> day(at, today) <> " " <> clock
    end
  end

  defp utc(%DateTime{} = at), do: DateTime.shift_zone!(at, "Etc/UTC")
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp utc(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> nil
    end
  end

  defp utc(_missing), do: nil
end
