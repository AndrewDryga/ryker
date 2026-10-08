defmodule Ryker.ControlPlane.ChartAxisTest do
  # The usage and feedback charts each held a copy of these until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.ChartAxis

  test "every day of a week is labelled, and seven spread evenly over a longer span" do
    assert ChartAxis.ticks(0) == []
    assert ChartAxis.ticks(3) == [0, 1, 2]
    assert ChartAxis.ticks(7) == [0, 1, 2, 3, 4, 5, 6]
    assert ChartAxis.ticks(31) == [0, 5, 10, 15, 20, 25, 30]
  end

  test "a coordinate has two decimals and a day reads as the axis writes it" do
    assert ChartAxis.coord(190) == "190.00"
    assert ChartAxis.coord(12.345) == "12.35"
    assert ChartAxis.date(~D[2026-10-08]) == "08 Oct"
  end
end
