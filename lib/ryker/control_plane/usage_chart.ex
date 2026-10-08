defmodule Ryker.ControlPlane.UsageChart do
  @moduledoc "An accessible daily series. Missing dates keep their position, not a false adjacency."
  import Ryker.ControlPlane.ChartAxis, only: [coord: 1, date: 1, ticks: 1]
  alias Ryker.ControlPlane.Kit
  alias Ryker.Wording

  def render([]) do
    Kit.empty_html(
      variant: :bare,
      icon: :usage,
      title: "No model work in this window",
      text: "The daily tokens show here once Ryker works."
    )
  end

  def render(days) do
    days = Enum.sort_by(days, &Date.to_gregorian_days(&1.date))
    oldest = hd(days).date
    last = List.last(days).date
    first = Enum.max_by([oldest, Date.add(last, -365)], &Date.to_gregorian_days/1)
    days = Enum.filter(days, &(Date.compare(&1.date, first) != :lt))
    by_date = Map.new(days, &{&1.date, &1})

    series =
      Enum.map(
        Date.range(first, last),
        &Map.get(by_date, &1, %{date: &1, tokens: 0, attempts: 0, measured: 0})
      )

    maximum = max(Enum.max_by(days, & &1.tokens).tokens, 1)
    step = 680 / length(series)
    bar_width = min(step * 0.7, 48)

    [
      if Date.compare(first, oldest) == :gt do
        "<p>Chart shows the latest 366 calendar days with a recorded endpoint. Totals above still cover the selected period.</p>"
      else
        []
      end,
      "<figure class=\"usage-chart\"><figcaption><strong>",
      Wording.number(Enum.sum(Enum.map(days, & &1.tokens))),
      "</strong> tokens · ",
      date(first),
      " – ",
      date(last),
      "</figcaption><div class=\"chart-scroll\">",
      "<svg viewBox=\"0 0 800 240\" role=\"group\" aria-label=\"Daily measured token trend\"><title>Daily measured token trend</title>",
      Enum.map([0, 0.5, 1], fn fraction ->
        y = 190 - fraction * 156

        [
          "<line class=\"chart-grid\" x1=\"74\" x2=\"774\" y1=\"",
          coord(y),
          "\" y2=\"",
          coord(y),
          "\"/><text class=\"chart-axis\" x=\"64\" y=\"",
          coord(y + 5),
          "\" text-anchor=\"end\">",
          compact(round(maximum * fraction)),
          "</text>"
        ]
      end),
      Enum.with_index(series)
      |> Enum.map(fn {day, index} ->
        height = day.tokens / maximum * 156
        x = 84 + step * index + (step - bar_width) / 2

        [
          "<rect class=\"chart-bar\" tabindex=\"0\" role=\"img\" data-date=\"",
          Date.to_iso8601(day.date),
          "\" aria-label=\"",
          day_label(day),
          "\" x=\"",
          coord(x),
          "\" y=\"",
          coord(190 - height),
          "\" width=\"",
          coord(bar_width),
          "\" height=\"",
          coord(height),
          "\" rx=\"2\"><title>",
          day_label(day),
          "</title></rect>"
        ]
      end),
      ticks(length(series))
      |> Enum.uniq()
      |> Enum.map(fn index ->
        [
          "<text class=\"chart-axis\" x=\"",
          coord(84 + step * (index + 0.5)),
          "\" y=\"222\" text-anchor=\"middle\">",
          date(Enum.at(series, index).date),
          "</text>"
        ]
      end),
      "</svg></div></figure>"
    ]
  end

  defp day_label(day), do: date(day.date) <> ": " <> Wording.number(day.tokens) <> " tokens"

  defp compact(value) when value >= 1_000_000, do: coord(value / 1_000_000) <> "m"
  defp compact(value) when value >= 1000, do: coord(value / 1000) <> "k"
  defp compact(value), do: to_string(value)
end
