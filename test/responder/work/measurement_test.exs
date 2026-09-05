defmodule Responder.Work.MeasurementTest do
  use ExUnit.Case, async: true

  alias Responder.Work.Measurement

  # Unsuccessful turns consumed inference without appearing in Usage. When
  # collecting them, a missing price must not turn their reported tokens into
  # zero usage or an unverified provider cost into a measured dollar amount.
  test "missing or invalid prices retain tokens without manufacturing measured cost" do
    for usage <- [
          %{"input_tokens" => 12, "cost_usd" => 9},
          %{"input_tokens" => 12, "cost_recorded" => true},
          %{"input_tokens" => 12, "cost_recorded" => true, "cost_usd" => "unknown"}
        ] do
      measured = Measurement.prepare(%{"usage" => usage}, %{"target" => "codex:test"})
      assert measured.usage_recorded
      assert measured.usage_input_tokens == 12
      refute measured.usage_cost_recorded
      assert measured.usage_cost_usd == nil
    end
  end

  test "out of range telemetry cannot make a valid model answer fail a bigint write" do
    measured =
      Measurement.prepare(
        %{"usage" => %{"input_tokens" => 9_223_372_036_854_775_808}},
        %{"target" => "codex:test"}
      )

    refute measured.usage_recorded
    assert measured.usage_input_tokens == nil
    assert measured.measurement_error_code == "invalid_usage"
  end

  test "malformed provider measurements remain explicit instead of becoming zero usage" do
    measured =
      Measurement.prepare(
        %{
          "finished_at" => "2026-09-01T00:00:00Z",
          "queued_at" => "2026-09-01T00:00:02Z",
          "started_at" => "2026-09-01T00:00:01Z",
          "usage" => %{"cost_recorded" => true, "cost_usd" => "free", "input_tokens" => -1}
        },
        %{}
      )

    assert measured.execution_target == nil
    assert measured.usage_recorded == false
    assert measured.timing_recorded == false
    assert measured.measurement_error_code == "invalid_target,invalid_timing,invalid_usage"

    invalid_usage = Measurement.prepare(%{"usage" => []}, %{"target" => "safe"})
    assert invalid_usage.measurement_error_code == "invalid_usage"

    integer_cost =
      Measurement.prepare(
        %{"usage" => %{"cost_recorded" => true, "cost_usd" => 2}},
        %{"target" => "claude:opus"}
      )

    assert integer_cost.usage_recorded
    assert Decimal.equal?(integer_cost.usage_cost_usd, Decimal.new(2))

    invalid_cost =
      Measurement.prepare(
        %{
          "usage" => %{
            "cached_input_tokens" => 0,
            "cost_recorded" => true,
            "cost_usd" => "free",
            "input_tokens" => 1,
            "output_tokens" => 1,
            "reasoning_tokens" => 0
          }
        },
        %{"target" => "claude:opus"}
      )

    assert invalid_cost.measurement_error_code == "invalid_usage"

    invalid_timestamp =
      Measurement.prepare(
        %{
          "finished_at" => "not-a-time",
          "queued_at" => "2026-09-01T00:00:00Z",
          "started_at" => "2026-09-01T00:00:01Z"
        },
        %{"target" => "claude:opus"}
      )

    assert invalid_timestamp.measurement_error_code == "invalid_timing"
  end

  test "target labels always produce bounded display parts" do
    assert Measurement.target_parts(nil) == %{
             effort: "default",
             model: "default",
             provider: "unrecorded"
           }

    assert Measurement.target_parts("codex:gpt-5.6-sol/xhigh@work") == %{
             effort: "xhigh",
             model: "gpt-5.6-sol",
             provider: "codex"
           }

    assert Measurement.target_parts("local") == %{
             effort: "default",
             model: "default",
             provider: "local"
           }
  end
end
