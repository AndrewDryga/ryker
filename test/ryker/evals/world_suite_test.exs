defmodule Ryker.Evals.WorldSuiteTest do
  use ExUnit.Case, async: true

  alias Ryker.Evals.{WorldCase, WorldSuite}

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
        "explicit-operator-incident-offer",
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

    assert length(plan) == 54

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

  test "every observation lands in exactly one shard and a pair never splits" do
    # The full matrix is 186 observations at ~93 seconds each, run one after
    # another: 4.8 hours for one number. Shards run as separate VMs, so the
    # partition has to be a pure function of the ordered plan — every shard
    # derives its own slice from the same plan and nothing coordinates them —
    # and a candidate/baseline pair of one scenario and repeat must stay on one
    # shard, or the merged paired comparison would depend on which shard was
    # slower.
    assert {:ok, cases} = WorldCase.all()
    assert {:ok, plan} = WorldSuite.plan(cases, repeat: 3, paired_baseline: true)
    assert length(plan) == 2 * 3 * length(cases)

    for count <- [1, 2, 3, 4, 7, 5_000] do
      shards = Enum.map(1..count, &shard!(plan, &1, count))
      assert Enum.sort(List.flatten(shards)) == Enum.sort(plan), "shard count #{count}"

      for shard <- shards do
        # A shard keeps the plan's own order, which is what the run log shows.
        assert shard == Enum.filter(plan, &(&1 in shard))

        pairs = Enum.group_by(shard, &{&1.scenario.id, &1.repeat_index}, & &1.lane)

        assert Enum.all?(pairs, fn {_pair, lanes} ->
                 Enum.sort(lanes) == [:baseline, :candidate]
               end)
      end

      # Round-robin over scenario/repeat pairs: no shard carries more than one
      # pair over any other, so the slowest shard bounds the wall clock.
      sizes = Enum.map(shards, &length/1)
      assert Enum.max(sizes) - Enum.min(Enum.reject(sizes, &(&1 == 0))) <= 2
    end

    # One shard is today's plan, unchanged.
    assert shard!(plan, 1, 1) == plan

    # A plan smaller than the shard count leaves the surplus shards empty
    # rather than duplicating observations to fill them.
    assert {:ok, small} =
             WorldSuite.plan(cases,
               scenario_id: "ordinary-thread-question-gets-natural-answer",
               repeat: 1
             )

    assert shard!(small, 1, 4) == small
    assert shard!(small, 2, 4) == []
    assert shard!(small, 4, 4) == []
  end

  test "a shard outside its count is refused" do
    assert {:ok, cases} = WorldCase.all()
    assert {:ok, plan} = WorldSuite.plan(cases)

    assert WorldSuite.shard(plan, 3, 2) == {:error, {:invalid_world_suite, :shard}}
    assert WorldSuite.shard(plan, 0, 4) == {:error, {:invalid_world_suite, :shard}}
    assert WorldSuite.shard(plan, 1, 0) == {:error, {:invalid_world_suite, :shard}}
    assert WorldSuite.shard(plan, "1", 2) == {:error, {:invalid_world_suite, :shard}}
    assert WorldSuite.shard(:invalid, 1, 1) == {:error, {:invalid_world_suite, :plan}}
  end

  defp shard!(plan, index, count) do
    assert {:ok, shard} = WorldSuite.shard(plan, index, count)
    shard
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

  for {field, value} <- [execution_error: nil, cleanup_error: false] do
    @failure_field field
    @failure_value value

    test "#{field} in the last observation cannot pass permissive quality thresholds" do
      # The last failed case has no successor to mark unrun. Treating a cleanup
      # error as an ordinary tolerated miss would qualify and drop its retained DB.
      last = report("same-case", 3, :failed) |> Map.put(@failure_field, @failure_value)
      reports = [report("same-case", 1, :passed), report("same-case", 2, :passed), last]

      assert {:ok, summary} =
               WorldSuite.summarize(reports,
                 min_overall_pass_rate: 2 / 3,
                 min_case_pass_rate: 2 / 3
               )

      refute summary.passed?
      assert summary.candidate.hard_failure_count == 0
      assert summary.candidate.per_case["same-case"].hard_failure_count == 0
      assert summary.failures == [%{kind: @failure_field, actual: 1, required: 0}]
    end
  end

  test "an assertion failure and cleanup failure keep separate qualification diagnostics" do
    failed =
      report("same-case", 3, :failed, [%{"kind" => "delivery_target"}])
      |> Map.put(:cleanup_error, :remote_cleanup_failed)

    reports = [report("same-case", 1, :passed), report("same-case", 2, :passed), failed]

    assert {:ok, summary} =
             WorldSuite.summarize(reports,
               min_overall_pass_rate: 2 / 3,
               min_case_pass_rate: 2 / 3
             )

    refute summary.passed?
    assert summary.candidate.hard_failure_count == 1
    assert summary.candidate.per_case["same-case"].hard_failure_count == 1
    assert %{kind: :hard_invariant, actual: 1, required: 0} in summary.failures
    assert %{kind: :cleanup_error, actual: 1, required: 0} in summary.failures
  end

  test "ordinary quality failures retain their configured threshold tolerance" do
    reports = [
      report("same-case", 1, :passed),
      report("same-case", 2, :passed),
      report("same-case", 3, :failed)
    ]

    assert {:ok, summary} =
             WorldSuite.summarize(reports,
               min_overall_pass_rate: 2 / 3,
               min_case_pass_rate: 2 / 3
             )

    assert summary.passed?
    assert summary.candidate.hard_failure_count == 0
    assert summary.failures == []
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

  test "baseline hard failures remain comparison evidence and do not veto the candidate" do
    reports = [
      report("case-a", 1, :failed, [%{"kind" => "state_tool_recorded"}], :baseline),
      report("case-a", 1, :passed)
    ]

    assert {:ok, summary} =
             WorldSuite.summarize(reports,
               paired_baseline: true,
               min_overall_pass_rate: 1.0,
               min_case_pass_rate: 1.0
             )

    assert summary.passed?
    assert summary.baseline.hard_failure_count == 1
    assert summary.candidate.hard_failure_count == 0
    assert summary.failures == []
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
