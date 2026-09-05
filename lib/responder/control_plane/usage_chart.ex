defmodule Responder.ControlPlane.UsageChart do
  @moduledoc "An accessible daily series. Missing dates keep their position, not a false adjacency."
  def render([]), do: "<p class=\"empty\">No executions recorded in this window.</p>"

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
      if(Date.compare(first, oldest) == :gt,
        do:
          "<p>Chart shows the latest 366 calendar days with a recorded endpoint. Totals above still cover the selected period.</p>",
        else: []
      ),
      "<figure class=\"usage-chart\"><figcaption><strong>",
      number(Enum.sum(Enum.map(days, & &1.tokens))),
      "</strong> tokens · ",
      date(first),
      " – ",
      date(last),
      "</figcaption><div class=\"chart-scroll\">",
      "<svg viewBox=\"0 0 800 240\" role=\"img\" aria-label=\"Daily measured token trend\"><title>Daily measured token trend</title>",
      "<desc>Tokens per day. Exact values are in the Daily values table below.</desc>",
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
          "<rect class=\"chart-bar\" x=\"",
          coord(x),
          "\" y=\"",
          coord(190 - height),
          "\" width=\"",
          coord(bar_width),
          "\" height=\"",
          coord(height),
          "\" rx=\"2\"><title>",
          date(day.date),
          ": ",
          number(day.tokens),
          " counters; ",
          to_string(day.measured),
          " of ",
          to_string(day.attempts),
          " measured</title></rect>"
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
      "</svg></div><details id=\"daily-values\"><summary>Daily values</summary><div class=\"table-wrap\"><table><thead><tr><th>Day</th><th>Tokens</th><th>Executions</th></tr></thead><tbody>",
      Enum.map(series, fn day ->
        [
          "<tr><td><time datetime=\"",
          Date.to_iso8601(day.date),
          "\">",
          date(day.date),
          "</time></td><td><strong>",
          number(day.tokens),
          "</strong></td><td>",
          if(day.attempts == 0,
            do: "No executions",
            else: to_string(day.attempts)
          ),
          "</td></tr>"
        ]
      end),
      "</tbody></table></div></details></figure>"
    ]
  end

  defp date(date), do: Calendar.strftime(date, "%d %b")
  defp ticks(count) when count <= 7, do: Enum.to_list(0..(count - 1))
  defp ticks(count), do: Enum.uniq(Enum.map(0..6, &round(&1 * (count - 1) / 6)))
  defp coord(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
  defp number(value), do: to_string(value) |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  defp compact(value) when value >= 1_000_000, do: coord(value / 1_000_000) <> "m"
  defp compact(value) when value >= 1000, do: coord(value / 1000) <> "k"
  defp compact(value), do: to_string(value)
end
