defmodule Ryker.ControlPlane.Units do
  @moduledoc """
  How the console writes a measure, the same on every page: a duration in
  words, a size in binary units, and an amount of money in dollars.

  Each page had its own, and they disagreed: durations in four styles
  ("16.5 s", "16.5s", "4.2m", "1m 5s"), money rounded three ways, and sizes in
  GiB, GB, KiB and a 1024-based "MB" (2026-10-04 review).
  """

  @doc "A duration: 0 s, 850 ms, 5 s, 16.5 s, 4 min, 4 min 10 s, 2 h, 2 h 5 min."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(0), do: "0 s"
  def duration(ms) when is_integer(ms) and ms < 1_000, do: "#{ms} ms"
  def duration(ms) when is_integer(ms) and ms < 60_000, do: one_place(ms / 1_000) <> " s"

  def duration(ms) when is_integer(ms) and ms < 3_600_000 do
    seconds = div(ms, 1_000)
    joined(div(seconds, 60), "min", rem(seconds, 60), "s")
  end

  def duration(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    joined(div(minutes, 60), "h", rem(minutes, 60), "min")
  end

  @doc "A size in binary units: 512 bytes, 12 KiB, 3.4 MiB, 1.2 GiB."
  @spec bytes(non_neg_integer()) :: String.t()
  def bytes(count) when is_integer(count) and count < 1_024, do: "#{count} bytes"
  def bytes(count) when is_integer(count) and count < 1_048_576, do: "#{div(count, 1_024)} KiB"

  def bytes(count) when is_integer(count) and count < 1_073_741_824,
    do: one_place(count / 1_048_576) <> " MiB"

  def bytes(count) when is_integer(count), do: one_place(count / 1_073_741_824) <> " GiB"

  @doc """
  An amount of dollars: to the cent from ten cents up, and to two significant
  digits below, so one model call reads $0.026 rather than $0.03 or free; "$0"
  for nothing, and "≈" before an estimate.
  """
  @spec money(Decimal.t(), boolean()) :: String.t()
  def money(amount, estimated \\ false)

  def money(%Decimal{} = amount, estimated) do
    if Decimal.eq?(amount, 0) do
      "$0"
    else
      prefix = if estimated, do: "≈ $", else: "$"
      prefix <> (amount |> Decimal.round(places(amount)) |> Decimal.to_string(:normal))
    end
  end

  # Two significant digits: 0.026 needs three places, 0.0042 four.
  defp places(amount) do
    if Decimal.lt?(Decimal.abs(amount), Decimal.new("0.1")),
      do: 1 - floor(:math.log10(Decimal.to_float(Decimal.abs(amount)))),
      else: 2
  end

  @doc """
  What a set of model calls cost, from usage totals (`Ryker.Accounting.Query`):
  reported cost plus what is estimated from saved prices, and "Not measured"
  when no call was priced. It reads "≈" when any of it is an estimate, unless
  the page says so its own way, as Usage does beside its rates.
  """
  @spec cost(map(), boolean()) :: String.t()
  def cost(totals, mark_estimate \\ true) do
    estimated = totals[:estimated] || 0

    if (totals[:costed] || 0) + estimated > 0 do
      (totals[:cost_usd] || Decimal.new(0))
      |> Decimal.add(totals[:estimated_cost_usd] || Decimal.new(0))
      |> money(mark_estimate and estimated > 0)
    else
      "Not measured"
    end
  end

  defp one_place(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  defp joined(whole, unit, 0, _part_unit), do: "#{whole} #{unit}"
  defp joined(whole, unit, part, part_unit), do: "#{whole} #{unit} #{part} #{part_unit}"
end
