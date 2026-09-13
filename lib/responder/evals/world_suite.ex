defmodule Responder.Evals.WorldSuite do
  @moduledoc """
  Plans and qualifies repeated fabricated-world model evaluations.

  Deterministic host replay stays single-run. This module exists only at the
  model-present release boundary, where one lucky answer is not evidence and a
  changing baseline world would make comparison meaningless.
  """

  alias Responder.Evals.WorldCase

  @maximum_repeats 10
  @lanes [:baseline, :candidate]
  @statuses [:failed, :passed, :unrun]

  @spec select([WorldCase.t()], keyword() | map()) ::
          {:ok, [WorldCase.t()]} | {:error, term()}
  def select(cases, options \\ [])

  def select(cases, options) when is_list(cases) do
    with true <- Enum.all?(cases, &match?(%WorldCase{}, &1)) or invalid(:cases),
         {:ok, settings} <- selection_options(options) do
      selected(cases, settings)
    end
  end

  def select(_cases, _options), do: invalid(:cases)

  @spec plan([WorldCase.t()], keyword() | map()) :: {:ok, [map()]} | {:error, term()}
  def plan(cases, options \\ []) do
    with {:ok, settings} <- plan_options(options),
         {:ok, selected} <- select(cases, Map.take(settings, [:scenario_id, :tag])) do
      lanes = if settings.paired_baseline, do: @lanes, else: [:candidate]

      plan =
        for scenario <- selected,
            repeat_index <- 1..settings.repeat,
            lane <- lanes,
            do: %{lane: lane, repeat_index: repeat_index, scenario: scenario}

      {:ok, plan}
    end
  end

  @doc """
  The slice of a plan that shard `index` of `count` runs.

  Shards are separate VMs that never talk to each other, so the partition is a
  pure function of the ordered plan: scenario/repeat pairs are dealt round-robin
  in plan order, and a pair's candidate and baseline observations always land
  on the same shard so the merged paired comparison is independent of
  scheduling. One shard of one is the plan itself. A plan with fewer pairs than
  shards leaves the surplus shards empty rather than repeating an observation.
  """
  @spec shard([map()], pos_integer(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def shard(plan, index, count)
      when is_list(plan) and is_integer(index) and is_integer(count) and count >= 1 and
             index in 1..count//1 do
    if Enum.all?(plan, &observation?/1) do
      pairs = plan |> Enum.map(&pair/1) |> Enum.uniq() |> Enum.with_index() |> Map.new()

      {:ok, Enum.filter(plan, &(rem(Map.fetch!(pairs, pair(&1)), count) + 1 == index))}
    else
      invalid(:plan)
    end
  end

  def shard(plan, _index, _count) when is_list(plan), do: invalid(:shard)
  def shard(_plan, _index, _count), do: invalid(:plan)

  defp observation?(%{lane: lane, repeat_index: repeat_index, scenario: %WorldCase{}}),
    do: lane in @lanes and repeat_index in 1..@maximum_repeats

  defp observation?(_observation), do: false

  defp pair(observation), do: {observation.scenario.id, observation.repeat_index}

  @spec summarize([map()], keyword() | map()) :: {:ok, map()} | {:error, term()}
  def summarize(reports, options \\ [])

  def summarize(reports, options) when is_list(reports) and reports != [] do
    with {:ok, settings} <- summary_options(options),
         :ok <- validate_reports(reports),
         :ok <- unique_observations(reports),
         {:ok, lanes} <- report_lanes(reports, settings.paired_baseline),
         {:ok, paired} <- paired(lanes, settings) do
      candidate = statistics(lanes.candidate)
      baseline = statistics(lanes.baseline)

      failures =
        invariant_failures(lanes.candidate) ++
          threshold_failures(candidate, settings) ++ paired_failures(paired, settings)

      {:ok,
       %{
         baseline: baseline,
         candidate: candidate,
         failures: failures,
         paired: paired,
         passed?: failures == [],
         thresholds: settings
       }}
    end
  end

  def summarize(_reports, _options), do: invalid(:reports)

  defp selection_options(options) do
    with {:ok, options} <- options(options, [:scenario_id, :tag]),
         scenario_id <- Map.get(options, :scenario_id),
         tag <- Map.get(options, :tag),
         :ok <- optional_reference(scenario_id, :scenario_id),
         :ok <- optional_reference(tag, :tag),
         true <- is_nil(scenario_id) or is_nil(tag) or invalid(:selection) do
      {:ok, %{scenario_id: scenario_id, tag: tag}}
    end
  end

  defp plan_options(options) do
    with {:ok, options} <- options(options, [:paired_baseline, :repeat, :scenario_id, :tag]),
         {:ok, selection} <- selection_options(Map.take(options, [:scenario_id, :tag])),
         repeat <- Map.get(options, :repeat, 1),
         paired <- Map.get(options, :paired_baseline, false),
         true <- repeat in 1..@maximum_repeats or invalid(:repeat),
         true <- is_boolean(paired) or invalid(:paired_baseline) do
      {:ok, Map.merge(selection, %{paired_baseline: paired, repeat: repeat})}
    end
  end

  defp summary_options(options) do
    fields = [
      :max_paired_regression,
      :min_case_pass_rate,
      :min_overall_pass_rate,
      :paired_baseline
    ]

    with {:ok, options} <- options(options, fields),
         settings <- %{
           max_paired_regression: Map.get(options, :max_paired_regression, 0.1),
           min_case_pass_rate: Map.get(options, :min_case_pass_rate, 2 / 3),
           min_overall_pass_rate: Map.get(options, :min_overall_pass_rate, 0.9),
           paired_baseline: Map.get(options, :paired_baseline, false)
         },
         :ok <- rate(settings.max_paired_regression, :max_paired_regression),
         :ok <- rate(settings.min_case_pass_rate, :min_case_pass_rate),
         :ok <- rate(settings.min_overall_pass_rate, :min_overall_pass_rate),
         true <- is_boolean(settings.paired_baseline) or invalid(:paired_baseline) do
      {:ok, settings}
    end
  end

  defp options(options, allowed) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options(allowed),
      else: invalid(:options)
  end

  defp options(%{} = options, allowed) do
    if Map.keys(options) -- allowed == [], do: {:ok, options}, else: invalid(:options)
  end

  defp options(_options, _allowed), do: invalid(:options)

  defp selected(cases, %{scenario_id: scenario_id, tag: tag}) do
    selected =
      cond do
        is_binary(scenario_id) -> Enum.filter(cases, &(&1.id == scenario_id))
        is_binary(tag) -> Enum.filter(cases, &(tag in &1.tags))
        true -> cases
      end

    if selected == [],
      do: {:error, {:world_suite_selection_empty, %{scenario_id: scenario_id, tag: tag}}},
      else: {:ok, selected}
  end

  defp validate_reports(reports) do
    if Enum.all?(reports, &valid_report?/1), do: :ok, else: invalid(:report)
  end

  defp valid_report?(%{
         failures: failures,
         lane: lane,
         repeat_index: repeat_index,
         scenario_id: scenario_id,
         status: status
       }) do
    is_list(failures) and lane in @lanes and repeat_index in 1..@maximum_repeats and
      reference?(scenario_id) and status in @statuses
  end

  defp valid_report?(_report), do: false

  defp unique_observations(reports) do
    identities = Enum.map(reports, &{&1.lane, &1.scenario_id, &1.repeat_index})

    if Enum.uniq(identities) == identities,
      do: :ok,
      else: invalid(:duplicate_observation)
  end

  defp report_lanes(reports, paired_baseline) do
    lanes = %{
      baseline: Enum.filter(reports, &(&1.lane == :baseline)),
      candidate: Enum.filter(reports, &(&1.lane == :candidate))
    }

    cond do
      paired_baseline -> {:ok, lanes}
      lanes.candidate == [] -> invalid(:candidate_reports)
      lanes.baseline != [] -> invalid(:unexpected_baseline)
      true -> {:ok, lanes}
    end
  end

  defp paired(%{candidate: candidate, baseline: baseline}, %{paired_baseline: true}) do
    candidate = observation_map(candidate)
    baseline = observation_map(baseline)
    candidate_keys = candidate |> Map.keys() |> MapSet.new()
    baseline_keys = baseline |> Map.keys() |> MapSet.new()

    if candidate_keys == baseline_keys do
      {:ok, paired_statistics(candidate, baseline)}
    else
      {:error,
       {:world_suite_pair_mismatch,
        %{
          baseline_only: difference(baseline_keys, candidate_keys),
          candidate_only: difference(candidate_keys, baseline_keys)
        }}}
    end
  end

  defp paired(%{baseline: []}, %{paired_baseline: false}), do: {:ok, nil}

  defp observation_map(reports) do
    Map.new(reports, &{{&1.scenario_id, &1.repeat_index}, &1})
  end

  defp paired_statistics(candidate, baseline) do
    baseline_passed = Enum.count(baseline, fn {_key, report} -> report.status == :passed end)

    regressions =
      Enum.count(baseline, fn {key, report} ->
        report.status == :passed and Map.fetch!(candidate, key).status != :passed
      end)

    candidate_pass_rate = pass_rate(Map.values(candidate))
    baseline_pass_rate = pass_rate(Map.values(baseline))

    %{
      baseline_passed: baseline_passed,
      pass_rate_delta: candidate_pass_rate - baseline_pass_rate,
      regression_rate: ratio(regressions, baseline_passed),
      regressions: regressions,
      total: map_size(candidate)
    }
  end

  defp difference(left, right) do
    left |> MapSet.difference(right) |> Enum.sort()
  end

  defp statistics([]) do
    %{
      failed: 0,
      hard_failure_count: 0,
      passed: 0,
      pass_rate: 0.0,
      per_case: %{},
      total: 0,
      unrun: 0
    }
  end

  defp statistics(reports) do
    %{
      failed: Enum.count(reports, &(&1.status == :failed)),
      hard_failure_count: Enum.sum(Enum.map(reports, &length(&1.failures))),
      passed: Enum.count(reports, &(&1.status == :passed)),
      pass_rate: pass_rate(reports),
      per_case: per_case(reports),
      total: length(reports),
      unrun: Enum.count(reports, &(&1.status == :unrun))
    }
  end

  defp per_case(reports) do
    reports
    |> Enum.group_by(& &1.scenario_id)
    |> Map.new(fn {scenario_id, values} -> {scenario_id, statistics_without_cases(values)} end)
  end

  defp statistics_without_cases(reports) do
    %{
      failed: Enum.count(reports, &(&1.status == :failed)),
      hard_failure_count: Enum.sum(Enum.map(reports, &length(&1.failures))),
      passed: Enum.count(reports, &(&1.status == :passed)),
      pass_rate: pass_rate(reports),
      total: length(reports),
      unrun: Enum.count(reports, &(&1.status == :unrun))
    }
  end

  defp pass_rate(reports) do
    ratio(Enum.count(reports, &(&1.status == :passed)), length(reports))
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp invariant_failures(reports) do
    unrun = Enum.count(reports, &(&1.status == :unrun))
    hard = Enum.sum(Enum.map(reports, &length(&1.failures)))
    execution = Enum.count(reports, &Map.has_key?(&1, :execution_error))
    cleanup = Enum.count(reports, &Map.has_key?(&1, :cleanup_error))

    []
    |> maybe_failure(unrun > 0, %{actual: unrun, kind: :unrun, required: 0})
    |> maybe_failure(hard > 0, %{actual: hard, kind: :hard_invariant, required: 0})
    |> maybe_failure(execution > 0, %{actual: execution, kind: :execution_error, required: 0})
    |> maybe_failure(cleanup > 0, %{actual: cleanup, kind: :cleanup_error, required: 0})
  end

  defp threshold_failures(candidate, settings) do
    case_failures =
      candidate.per_case
      |> Enum.filter(fn {_scenario_id, result} ->
        result.pass_rate < settings.min_case_pass_rate
      end)
      |> Enum.map(fn {scenario_id, result} ->
        %{
          actual: result.pass_rate,
          kind: :case_pass_rate,
          required: settings.min_case_pass_rate,
          scenario_id: scenario_id
        }
      end)
      |> Enum.sort_by(& &1.scenario_id)

    []
    |> maybe_failure(candidate.pass_rate < settings.min_overall_pass_rate, %{
      actual: candidate.pass_rate,
      kind: :overall_pass_rate,
      required: settings.min_overall_pass_rate
    })
    |> Kernel.++(case_failures)
  end

  defp paired_failures(nil, _settings), do: []

  defp paired_failures(paired, settings) do
    []
    |> maybe_failure(paired.regression_rate > settings.max_paired_regression, %{
      actual: paired.regression_rate,
      kind: :paired_regression,
      required_maximum: settings.max_paired_regression
    })
  end

  defp maybe_failure(failures, true, failure), do: failures ++ [failure]
  defp maybe_failure(failures, false, _failure), do: failures

  defp optional_reference(nil, _field), do: :ok

  defp optional_reference(value, field) do
    if reference?(value), do: :ok, else: invalid(field)
  end

  defp reference?(value) when is_binary(value) and byte_size(value) in 1..256 do
    String.valid?(value) and String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch
  end

  defp reference?(_value), do: false

  defp rate(value, _field) when is_number(value) and value >= 0 and value <= 1, do: :ok
  defp rate(_value, field), do: invalid(field)

  defp invalid(field), do: {:error, {:invalid_world_suite, field}}
end
