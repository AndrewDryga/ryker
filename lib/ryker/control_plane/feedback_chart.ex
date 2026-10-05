defmodule Ryker.ControlPlane.FeedbackChart do
  @moduledoc """
  Feedback by day as a chart, drawn the way Usage & cost draws its tokens:
  one bar a day, oldest on the left, a day with none keeping its place. Each
  bar is stacked by which way the feedback went: negative (frustrated, asked
  again, edited or deleted), neutral and positive (satisfied).

  Andrew, 2026-09-28: "By day … should be a graph like in usage and above
  table".
  """
  use Phoenix.Component

  @tones [
    negative: [:frustrated, :asked_again, :edited],
    neutral: [:neutral],
    positive: [:satisfied]
  ]

  # The drawing area inside the 800 × 240 view box, as Usage's chart has it.
  @left 84
  @width 690
  @bottom 190
  @height 156
  @max_days 366

  @doc "The categories each way feedback went holds, negative first."
  def tones, do: @tones

  attr(:days, :list, required: true, doc: "[%{day: Date, counts: %{category => count}}]")

  @doc "The chart for the days that have feedback, in any order; nothing for none."
  def chart(%{days: []} = assigns), do: ~H""

  def chart(assigns) do
    series = series(assigns.days)
    top = series |> Enum.map(& &1.total) |> Enum.max() |> nice_top()
    step = @width / length(series)
    bar = min(step * 0.7, 48)

    assigns =
      assign(assigns,
        total: series |> Enum.map(& &1.total) |> Enum.sum(),
        first: hd(series).date,
        last: List.last(series).date,
        grid:
          for {fraction, label} <- [{0, 0}, {0.5, div(top, 2)}, {1, top}] do
            {coord(@bottom - fraction * @height), coord(@bottom - fraction * @height + 5), label}
          end,
        bars:
          for {day, index} <- Enum.with_index(series) do
            %{
              date: day.date,
              label: label(day),
              x: coord(@left + step * index + (step - bar) / 2),
              width: coord(bar),
              segments: segments(day, top)
            }
          end,
        ticks:
          for index <- ticks(length(series)) do
            {coord(@left + step * (index + 0.5)), date(Enum.at(series, index).date)}
          end,
        legend:
          Enum.filter(Keyword.keys(@tones), fn tone -> Enum.any?(series, &(&1[tone] > 0)) end)
      )

    ~H"""
    <figure class="usage-chart feedback-chart">
      <figcaption>
        <strong>{@total}</strong>
        {if @total == 1, do: "piece of feedback", else: "pieces of feedback"} · {span(@first, @last)}
        <span class="feedback-chart-legend">
          <span :for={tone <- @legend} class={"feedback-key feedback-key-#{tone}"}>{word(tone)}</span>
        </span>
      </figcaption>
      <div class="chart-scroll">
        <svg viewBox="0 0 800 240" role="group" aria-label="Feedback by day">
          <title>Feedback by day</title>
          <g :for={{y, label_y, label} <- @grid}>
            <line class="chart-grid" x1="74" x2="774" y1={y} y2={y} />
            <text class="chart-axis" x="64" y={label_y} text-anchor="end">{label}</text>
          </g>
          <g
            :for={bar <- @bars}
            class="feedback-chart-day"
            tabindex="0"
            role="img"
            aria-label={bar.label}
            data-date={Date.to_iso8601(bar.date)}
          >
            <title>{bar.label}</title>
            <rect
              :for={{tone, y, height} <- bar.segments}
              class={"feedback-bar feedback-bar-#{tone}"}
              x={bar.x}
              y={y}
              width={bar.width}
              height={height}
            />
          </g>
          <text :for={{x, label} <- @ticks} class="chart-axis" x={x} y="222" text-anchor="middle">
            {label}
          </text>
        </svg>
      </div>
    </figure>
    """
  end

  # Every calendar day from the oldest with feedback to the newest, at most a
  # year of them, each with how much went each way.
  defp series(days) do
    counts = Map.new(days, &{&1.day, &1.counts})
    last = days |> Enum.map(& &1.day) |> Enum.max(Date)
    oldest = days |> Enum.map(& &1.day) |> Enum.min(Date)
    first = Enum.max([oldest, Date.add(last, 1 - @max_days)], Date)

    for date <- Date.range(first, last) do
      day = Map.get(counts, date, %{})

      tones =
        Map.new(@tones, fn {tone, categories} ->
          {tone, categories |> Enum.map(&Map.get(day, &1, 0)) |> Enum.sum()}
        end)

      Map.merge(tones, %{date: date, total: tones |> Map.values() |> Enum.sum()})
    end
  end

  # Negative at the foot of each bar, positive on top.
  defp segments(day, top) do
    {segments, _base} =
      Enum.flat_map_reduce(Keyword.keys(@tones), 0, fn tone, base ->
        case day[tone] do
          0 ->
            {[], base}

          count ->
            height = count / top * @height
            {[{tone, coord(@bottom - base - height), coord(height)}], base + height}
        end
      end)

    segments
  end

  # An even top, so the middle line is a whole number too.
  defp nice_top(maximum) when maximum <= 2, do: 2
  defp nice_top(maximum), do: maximum + rem(maximum, 2)

  defp label(%{total: 0} = day), do: date(day.date) <> ": no feedback"

  defp label(day) do
    parts =
      for tone <- Keyword.keys(@tones),
          day[tone] > 0,
          do: "#{day[tone]} #{String.downcase(word(tone))}"

    date(day.date) <> ": " <> Enum.join(parts, ", ")
  end

  defp word(:negative), do: "Negative"
  defp word(:neutral), do: "Neutral"
  defp word(:positive), do: "Positive"

  defp ticks(count) when count <= 7, do: Enum.to_list(0..(count - 1))
  defp ticks(count), do: Enum.uniq(Enum.map(0..6, &round(&1 * (count - 1) / 6)))

  defp span(day, day), do: date(day)
  defp span(first, last), do: date(first) <> " – " <> date(last)

  defp date(date), do: Calendar.strftime(date, "%d %b")
  defp coord(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
end
