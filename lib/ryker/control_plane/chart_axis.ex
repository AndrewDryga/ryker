defmodule Ryker.ControlPlane.ChartAxis do
  @moduledoc """
  What the console's daily charts share: which days are labelled under the
  axis, an SVG coordinate, and a day as the axis writes it.
  """

  @doc """
  The positions, of `count` days, that carry a label: every day up to a
  week, otherwise seven spread evenly from the first to the last.
  """
  @spec ticks(non_neg_integer()) :: [non_neg_integer()]
  def ticks(count) when count <= 7, do: Enum.to_list(0..(count - 1)//1)
  def ticks(count), do: Enum.uniq(Enum.map(0..6, &round(&1 * (count - 1) / 6)))

  @doc "An SVG coordinate, with two decimals."
  @spec coord(number()) :: String.t()
  def coord(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  @doc ~s(A day as the axis writes it: "08 Oct".)
  @spec date(Date.t()) :: String.t()
  def date(date), do: Calendar.strftime(date, "%d %b")
end
