defmodule Ryker.RescuedTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Ryker.Rescued

  # Tools, readiness checks and lookups turned a raise into a soft answer and logged
  # nothing, so a host bug looked like an outage (2026-10-04 review). A lost database
  # connection is an outage every database caller reports already, so a polled check
  # does not repeat it.
  test "a rescued raise is logged with where it happened, a lost database connection is not" do
    {error, stacktrace} =
      try do
        raise ArgumentError, "bad shape"
      rescue
        error -> {error, __STACKTRACE__}
      end

    log = capture_log(fn -> assert :ok = Rescued.log("Readiness", error, stacktrace) end)
    assert log =~ "Readiness raised: ** (ArgumentError) bad shape"
    assert log =~ "rescued_test.exs"

    log =
      capture_log(fn ->
        assert {:error, "temporarily_unavailable"} =
                 Rescued.tool("Slack tool x", error, stacktrace)
      end)

    assert log =~ "Slack tool x raised"

    outage = %DBConnection.ConnectionError{message: "connection refused"}
    assert capture_log(fn -> Rescued.log("Readiness", outage, stacktrace) end) == ""
  end
end
