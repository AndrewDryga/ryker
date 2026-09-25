defmodule Ryker.ControlPlane.CallRunTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.CallRun

  # Harvested from routing attempt 2 of ingress-input:3edeb6b9 on 2026-09-23.
  # Its card read "Queue 3 ms · Model execution 16.5 s" for a call that took
  # 30.8 s from preparing to saving, and said nothing of its tokens or price.
  @attempt %{
    execution_target: "codex:gpt-5.6-sol/medium@default",
    milestones: %{
      "committed" => "2026-09-23T20:02:00.023026Z",
      "context_prepared" => "2026-09-23T20:01:29.255316Z",
      "execution_requested" => "2026-09-23T20:01:29.258247Z",
      "host_validation" => "2026-09-23T20:01:53.835360Z",
      "provider_queued" => "2026-09-23T20:01:39.510959Z",
      "provider_running" => "2026-09-23T20:01:43.584544Z",
      "request_frozen" => "2026-09-23T20:01:35.175353Z",
      "response_received" => "2026-09-23T20:01:53.830330Z"
    },
    measurements: %{
      "execution_target" => "codex:gpt-5.6-sol/medium@default",
      "remote_finished_at" => "2026-09-23T20:01:54.743976Z",
      "remote_queued_at" => "2026-09-23T20:01:38.249351Z",
      "remote_started_at" => "2026-09-23T20:01:38.252667Z",
      "timing_recorded" => true,
      "usage_cached_input_tokens" => 12_160,
      "usage_cost_recorded" => false,
      "usage_cost_usd" => nil,
      "usage_input_tokens" => 5_044,
      "usage_output_tokens" => 63,
      "usage_provider_ms" => 16_491,
      "usage_queued_ms" => 3,
      "usage_reasoning_tokens" => 0,
      "usage_recorded" => true
    },
    response: %{"state" => "completed", "validation_attempt" => 1}
  }

  # Harvested from the work turn that answered the greeting on 2026-09-24.
  @turn %{
    execution_target: "codex:gpt-5.6-terra/medium@default",
    usage_recorded: true,
    usage_input_tokens: 1_161,
    usage_cached_input_tokens: 21_760,
    usage_output_tokens: 46,
    usage_reasoning_tokens: 0,
    usage_cost_recorded: false,
    usage_cost_usd: nil,
    usage_provider_ms: 22_751,
    inserted_at: ~U[2026-09-24 06:05:13.034365Z],
    remote_started_at: ~U[2026-09-24 06:05:24.026655Z],
    remote_finished_at: ~U[2026-09-24 06:05:46.777699Z],
    accepted_at: ~U[2026-09-24 06:05:52.104325Z],
    candidate_attempt: 1,
    validation_history: [%{"candidate_attempt" => 1, "verdict" => "accept"}]
  }

  test "a routing call's time adds up from preparing to saving, with what it read and cost" do
    run = CallRun.from_attempt(@attempt)

    assert run.target == "codex:gpt-5.6-sol/medium@default"
    # Fresh input and cache reads are reported apart; the model read both.
    assert run.tokens == "17,204 in · 71% cached · 63 out"
    assert run.cost == "≈ $0.026"
    assert run.checks == "passed first time"

    assert Enum.map(run.segments, &{&1.kind, &1.ms}) == [
             prepare: 8_081,
             model: 16_491,
             save: 6_192
           ]

    assert run.total_ms == 30_767
    assert CallRun.duration(run.total_ms) == "30.8 s"
    # The parts never claim more time than the whole they explain.
    assert run.segments |> Enum.map(& &1.ms) |> Enum.sum() <= run.total_ms
  end

  test "a work turn's time starts when routing handed it over and ends when its answer was accepted" do
    run = CallRun.from_turn(@turn)

    assert run.tokens == "22,921 in · 95% cached · 46 out"
    assert run.cost == "≈ $0.0072"
    assert run.checks == "passed first time"

    assert Enum.map(run.segments, &{&1.kind, &1.ms}) == [
             prepare: 10_992,
             model: 22_751,
             save: 5_326
           ]

    assert CallRun.duration(run.total_ms) == "39.1 s"
  end

  test "an answer still being checked has no total and no saving time yet" do
    run = CallRun.from_turn(%{@turn | accepted_at: nil, candidate_attempt: nil})

    assert run.total_ms == nil
    assert Enum.map(run.segments, & &1.kind) == [:prepare, :model]
    assert run.checks == nil
  end

  test "a provider's own charge is shown as reported, never as an estimate" do
    measured =
      Map.merge(@attempt.measurements, %{
        "usage_cost_recorded" => true,
        "usage_cost_usd" => "0.0123"
      })

    assert CallRun.from_attempt(%{@attempt | measurements: measured}).cost == "$0.012"
  end

  test "a corrected answer says how many corrections it took" do
    assert CallRun.from_turn(%{@turn | candidate_attempt: 3}).checks ==
             "passed after 2 corrections"

    assert CallRun.from_attempt(%{
             @attempt
             | response: %{"state" => "completed", "validation_attempt" => 2}
           }).checks ==
             "passed after 1 correction"

    returned = %{@turn | accepted_at: nil, validation_history: [%{"verdict" => "reject"}]}
    assert CallRun.from_turn(returned).checks == "returned for correction"
  end

  test "durations read in the unit a person would use" do
    assert CallRun.duration(850) == "850 ms"
    assert CallRun.duration(16_491) == "16.5 s"
    assert CallRun.duration(250_000) == "4 min 10 s"
    assert CallRun.duration(7_500_000) == "2 h 5 min"
  end
end
