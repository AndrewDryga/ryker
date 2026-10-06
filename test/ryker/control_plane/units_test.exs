defmodule Ryker.ControlPlane.UnitsTest do
  @moduledoc """
  One way to write each measure on every page. Each page had its own, and
  they disagreed: durations in four styles, money rounded three ways, and
  sizes in GiB, GB, KiB and a 1024-based "MB" (2026-10-04 review).
  """
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.Units

  test "a duration reads in words, to the unit that matters" do
    assert Enum.map(
             [850, 5_000, 16_540, 240_000, 250_000, 7_200_000, 7_500_000],
             &Units.duration/1
           ) == ["850 ms", "5 s", "16.5 s", "4 min", "4 min 10 s", "2 h", "2 h 5 min"]
  end

  test "a size reads in binary units, named as such" do
    assert Enum.map(
             [512, 12_400, 3_565_158, 24_741_605_376],
             &Units.bytes/1
           ) == ["512 bytes", "12 KiB", "3.4 MiB", "23 GiB"]
  end

  test "money reads to the cent, below ten cents to two significant digits, and an estimate says so" do
    assert Units.money(Decimal.new("12.345")) == "$12.35"
    assert Units.money(Decimal.new("0.123")) == "$0.12"
    assert Units.money(Decimal.new("0.0261")) == "$0.026"
    assert Units.money(Decimal.new("0.00421")) == "$0.0042"
    assert Units.money(Decimal.new("0")) == "$0"
    assert Units.money(Decimal.new("1.5"), true) == "≈ $1.50"
  end

  test "a set of calls costs what was reported plus what was estimated, or is not measured" do
    reported = %{costed: 2, estimated: 0, cost_usd: Decimal.new("0.5"), estimated_cost_usd: nil}
    assert Units.cost(reported) == "$0.50"

    mixed = %{reported | estimated: 1, estimated_cost_usd: Decimal.new("0.25")}
    assert Units.cost(mixed) == "≈ $0.75"

    assert Units.cost(%{costed: 0, estimated: 0, cost_usd: nil, estimated_cost_usd: nil}) ==
             "Not measured"
  end
end
