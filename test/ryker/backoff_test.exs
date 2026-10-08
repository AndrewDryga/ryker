defmodule Ryker.BackoffTest do
  # Nineteen dispatchers, workers and pages each wrote this formula out until
  # 2026-10-08; the console's reload had no cap on its doublings at all.
  use ExUnit.Case, async: true
  alias Ryker.Backoff

  test "the first try waits the base, each further one twice as long, never past the maximum" do
    assert Enum.map(1..6, &Backoff.delay(&1, 5, 60)) == [5, 10, 20, 40, 60, 60]
  end

  test "an attempt before the first waits the base" do
    assert Backoff.delay(0, 5, 60) == 5
    assert Backoff.delay(-3, 5, 60) == 5
  end

  test "the doublings stop at their bound, so a long run of failures never computes a huge power" do
    assert Backoff.delay(100, 1, 1_000_000_000, 8) == 256
    assert Backoff.delay(1_000_000, 1, 3_600) == 3_600
  end
end
