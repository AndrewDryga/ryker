defmodule Ryker.ControlPlane.PageCostTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Ryker.ControlPlane.PageCost

  # A slow page was logged by its full path, Slack workspace and channel ids and request ids
  # with it, though the console's rule is never to log route parameters (2026-10-04 review).
  test "a slow page is logged by its kind, never by the ids in its path" do
    for {path, kind} <- [
          {"/channels/T0123456789/C0123456789", "/channels/:id/:id"},
          {"/timeline/0b0c3590-1f62-4ee0-a83c-0c12f21d83e6", "/timeline/:id"},
          {"/memory/learning", "/memory/learning"},
          {"/", "/"}
        ] do
      log =
        capture_log(fn ->
          PageCost.measure(path, true, fn ->
            for _query <- 1..300, do: PageCost.handle_query([], %{total_time: 0}, %{}, nil)
          end)
        end)

      assert log =~ "Slow page #{kind} (live): "
      refute log =~ ~r/T0123456789|C0123456789|0b0c3590/
    end
  end

  test "a page read slower than the configured time is logged as slow" do
    Ryker.Config.put_override(:page_slow_ms, 0)

    log = capture_log(fn -> PageCost.measure("/timeline", false, fn -> :ok end) end)

    assert log =~ "Slow page /timeline (first render): "
  end
end
