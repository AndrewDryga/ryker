defmodule Responder.Evals.WorldSuiteTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.{WorldCase, WorldSuite}

  test "case and tag selection produce a complete deterministic repeat plan" do
    assert {:ok, cases} = WorldCase.all()

    assert {:ok, [selected]} =
             WorldSuite.select(cases, scenario_id: "ordinary-thread-question-gets-natural-answer")

    assert selected.id == "ordinary-thread-question-gets-natural-answer"

    smoke_ids =
      MapSet.new([
        "airflow-verification-arms-wait",
        "artifact-delivery-survives-work-handoff",
        "concurrent-human-feedback-serializes",
        "current-uptime-check-uses-fresh-source",
        "github-pr-review-remains-in-thread",
        "ordinary-thread-question-gets-natural-answer",
        "rivals-engineering-task-offer",
        "va1-health-review-repairs-and-finishes"
      ])

    assert {:ok, selected} = WorldSuite.select(cases, tag: "smoke")
    assert MapSet.new(selected, & &1.id) == smoke_ids

    assert {:ok, plan} =
             WorldSuite.plan(cases,
               tag: "smoke",
               repeat: 3,
               paired_baseline: true
             )

    assert length(plan) == 48

    assert Enum.map(plan, &{&1.scenario.id, &1.repeat_index, &1.lane}) ==
             for(
               scenario <- selected,
               repeat_index <- 1..3,
               lane <- [:baseline, :candidate],
               do: {scenario.id, repeat_index, lane}
             )
  end

  test "selection and planning fail closed on empty, ambiguous, or unbounded requests" do
    assert {:ok, cases} = WorldCase.all()

    assert {:ok, candidate_plan} = WorldSuite.plan(cases)
    assert length(candidate_plan) == length(cases)
    assert Enum.all?(candidate_plan, &(&1.lane == :candidate and &1.repeat_index == 1))

    assert WorldSuite.select(cases,
             scenario_id: "ordinary-thread-question-gets-natural-answer",
             tag: "model-world"
           ) == {:error, {:invalid_world_suite, :selection}}

    assert WorldSuite.select(cases, scenario_id: "missing") ==
             {:error, {:world_suite_selection_empty, %{scenario_id: "missing", tag: nil}}}

    assert WorldSuite.select(cases, tag: "missing") ==
             {:error, {:world_suite_selection_empty, %{scenario_id: nil, tag: "missing"}}}

    assert WorldSuite.plan(cases, repeat: 0) ==
             {:error, {:invalid_world_suite, :repeat}}

    assert WorldSuite.plan(cases, repeat: 11) ==
             {:error, {:invalid_world_suite, :repeat}}

    assert WorldSuite.plan(cases, unknown: true) ==
             {:error, {:invalid_world_suite, :options}}

    assert WorldSuite.plan(:invalid) == {:error, {:invalid_world_suite, :cases}}

    assert WorldSuite.select(cases, tag: "smoke", tag: "model-world") ==
             {:error, {:invalid_world_suite, :options}}
  end

  test "candidate qualification enforces per-case, aggregate, hard, and unrun gates" do
    reports = [
      report("case-a", 1, :passed),
      report("case-a", 2, :passed),
      report("case-a", 3, :failed),
      report("case-b", 1, :passed),
      report("case-b", 2, :passed),
      report("case-b", 3, :passed)
    ]

    assert {:ok, summary} =
             WorldSuite.summarize(reports,
               min_overall_pass_rate: 0.8,
               min_case_pass_rate: 2 / 3
             )

    assert summary.passed?
    assert summary.candidate.total == 6
    assert summary.candidate.passed == 5
    assert summary.candidate.failed == 1
    assert summary.candidate.unrun == 0
    assert summary.candidate.hard_failure_count == 0
    assert_in_delta summary.candidate.pass_rate, 5 / 6, 1.0e-12
    assert_in_delta summary.candidate.per_case["case-a"].pass_rate, 2 / 3, 1.0e-12
    assert summary.failures == []

    reports = [
      report("case-a", 1, :passed),
      report("case-a", 2, :failed, [%{"kind" => "delivery_target"}]),
      report("case-a", 3, :unrun)
    ]

    assert {:ok, failed} =
             WorldSuite.summarize(reports,
               min_overall_pass_rate: 0.9,
               min_case_pass_rate: 2 / 3
             )

    refute failed.passed?
    assert failed.candidate.unrun == 1
    assert failed.candidate.hard_failure_count == 1
    assert Enum.any?(failed.failures, &(&1.kind == :unrun))
    assert Enum.any?(failed.failures, &(&1.kind == :hard_invariant))
    assert Enum.any?(failed.failures, &(&1.kind == :overall_pass_rate))
    assert Enum.any?(failed.failures, &(&1.kind == :case_pass_rate))
  end

  test "paired qualification compares the exact same scenario and repeat identities" do
    candidate = [
      report("case-a", 1, :passed),
      report("case-a", 2, :failed),
      report("case-a", 3, :passed)
    ]

    baseline = [
      report("case-a", 1, :passed, [], :baseline),
      report("case-a", 2, :passed, [], :baseline),
      report("case-a", 3, :passed, [], :baseline)
    ]

    assert {:ok, summary} =
             WorldSuite.summarize(baseline ++ candidate,
               paired_baseline: true,
               min_overall_pass_rate: 2 / 3,
               min_case_pass_rate: 2 / 3,
               max_paired_regression: 0.34
             )

    assert summary.passed?
    assert summary.paired.total == 3
    assert summary.paired.baseline_passed == 3
    assert summary.paired.regressions == 1
    assert_in_delta summary.paired.regression_rate, 1 / 3, 1.0e-12
    assert_in_delta summary.paired.pass_rate_delta, -1 / 3, 1.0e-12

    assert {:ok, failed} =
             WorldSuite.summarize(baseline ++ candidate,
               paired_baseline: true,
               min_overall_pass_rate: 2 / 3,
               min_case_pass_rate: 2 / 3,
               max_paired_regression: 0.1
             )

    refute failed.passed?
    assert Enum.any?(failed.failures, &(&1.kind == :paired_regression))
  end

  test "paired qualification refuses duplicate or unmatched observations" do
    candidate = report("case-a", 1, :passed)
    baseline = report("case-a", 1, :passed, [], :baseline)

    assert WorldSuite.summarize([candidate, candidate], []) ==
             {:error, {:invalid_world_suite, :duplicate_observation}}

    assert WorldSuite.summarize([candidate], paired_baseline: true) ==
             {:error,
              {:world_suite_pair_mismatch, %{baseline_only: [], candidate_only: [{"case-a", 1}]}}}

    assert WorldSuite.summarize([baseline], paired_baseline: true) ==
             {:error,
              {:world_suite_pair_mismatch, %{baseline_only: [{"case-a", 1}], candidate_only: []}}}

    assert WorldSuite.summarize([candidate], min_overall_pass_rate: 1.1) ==
             {:error, {:invalid_world_suite, :min_overall_pass_rate}}

    assert WorldSuite.summarize([candidate], min_case_pass_rate: -0.1) ==
             {:error, {:invalid_world_suite, :min_case_pass_rate}}

    assert WorldSuite.summarize([candidate], max_paired_regression: :invalid) ==
             {:error, {:invalid_world_suite, :max_paired_regression}}

    assert WorldSuite.summarize([baseline]) ==
             {:error, {:invalid_world_suite, :candidate_reports}}

    assert WorldSuite.summarize([candidate, baseline]) ==
             {:error, {:invalid_world_suite, :unexpected_baseline}}

    assert WorldSuite.summarize([Map.delete(candidate, :status)]) ==
             {:error, {:invalid_world_suite, :report}}

    assert WorldSuite.summarize([], []) == {:error, {:invalid_world_suite, :reports}}

    assert WorldSuite.summarize([candidate], paired_baseline: false, paired_baseline: true) ==
             {:error, {:invalid_world_suite, :options}}
  end

  test "a baseline with no passing observations has zero paired regression denominator" do
    reports = [
      report("case-a", 1, :failed, [], :baseline),
      report("case-a", 1, :passed)
    ]

    assert {:ok, summary} =
             WorldSuite.summarize(reports,
               paired_baseline: true,
               min_overall_pass_rate: 1.0,
               min_case_pass_rate: 1.0
             )

    assert summary.passed?
    assert summary.baseline.failed == 1
    assert summary.paired.baseline_passed == 0
    assert summary.paired.regression_rate == 0.0
    assert summary.paired.pass_rate_delta == 1.0
  end

  defp report(scenario_id, repeat_index, status, failures \\ [], lane \\ :candidate) do
    %{
      failures: failures,
      lane: lane,
      repeat_index: repeat_index,
      scenario_id: scenario_id,
      status: status
    }
  end
end
