defmodule Ryker.State.EventWaitTimingTest do
  use ExUnit.Case, async: true

  alias Ryker.State.EventWaitTiming
  alias Ryker.StateTools.FixedTools

  test "duration arithmetic preserves exact compound and fractional microseconds" do
    for {delay, microseconds} <- [
          {"10m", 600_000_000},
          {"1h30m", 5_400_000_000},
          {"1.5h", 5_400_000_000},
          {".5m0.25s", 30_250_000},
          {"0.000001s", 1},
          {"0.0000001h", 360},
          {"8760h", 31_536_000_000_000}
        ] do
      assert EventWaitTiming.delay_microseconds(delay) == {:ok, microseconds}

      assert EventWaitTiming.due_at(
               %{"type" => "after", "delay" => delay},
               ~U[2026-09-07 12:00:00Z]
             ) ==
               {:ok, DateTime.add(~U[2026-09-07 12:00:00Z], microseconds, :microsecond)}
    end
  end

  test "timer tools explain syntax, timing anchor, precision and hard deadline" do
    tool = Enum.find(FixedTools.list(capabilities: [:event_waits]), &(&1["name"] == "wait_for"))
    triggers = tool["inputSchema"]["properties"]["trigger"]["oneOf"]
    after_trigger = Enum.find(triggers, &Map.has_key?(&1["properties"], "delay"))
    at_trigger = Enum.find(triggers, &Map.has_key?(&1["properties"], "at"))
    description = after_trigger["properties"]["delay"]["description"]

    assert description =~ "s, m and h"
    assert description =~ "1h30m"
    assert description =~ "microsecond"
    assert description =~ "365 days"
    assert description =~ "original creation"
    assert description =~ "strictly before deadline"
    assert at_trigger["properties"]["at"]["description"] =~ "UTC"
  end
end
