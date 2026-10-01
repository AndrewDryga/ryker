defmodule Mix.Tasks.Ryker.Eval do
  @moduledoc """
  Exports or executes the versioned model-world scenarios.

      mix ryker.eval world-pack
      mix ryker.eval world --results /absolute/world-results.json
      mix ryker.eval world --results /absolute/shard-2.json --shard 2/4
      mix ryker.eval world-shards --shards 4
      mix ryker.eval world-merge --results /absolute/world-results.json \\
        /absolute/shard-1.json /absolute/shard-2.json
      mix ryker.eval routing-replay --examples /absolute/routing-examples.jsonl \\
        --results /absolute/routing-replay.json [--limit N] [--concurrency N] \\
        [--local-endpoint http://127.0.0.1:8181/v1 --local-model qwen2.5:3b]
      mix ryker.eval improvement-replay --runs /absolute/analysis-runs.jsonl \\
        --results /absolute/improvement-replay.json [--concurrency N]

  `world-pack` emits one JSON object per scenario, with its exact tool catalog,
  without calling a model. `world` runs the same scenarios through the
  dedicated worker named by `RYKER_EVAL_SOCKET`. `RYKER_EVAL_WORLD_TARGET`,
  `RYKER_EVAL_JUDGE_TARGET` and optional `RYKER_EVAL_BASELINE_TARGET` select
  models explicitly. Every job has an empty workspace and no project tools;
  only subject turns receive the scenario's controller tools. No production
  settings or operator-supplied policy digests are used.

  A world matrix is 31 scenarios × 3 repeats × 2 lanes, 186 observations at
  about 93 seconds each, so `scripts/elixir-world-eval.sh` runs it as shards:
  separate VMs, each on its own campaign database and listener ports, each
  running the slice `--shard I/N` deals it from the same ordered plan and
  writing results without a verdict. `world-shards` previews which shards a
  plan fills so no empty VM is started, and `world-merge` joins the partial
  results into the one report the thresholds and the trend tooling read.

  `routing-replay` asks the routing decisions in a routing examples export
  again, each with today's instructions and contract, on the model
  `RYKER_EVAL_ROUTING_TARGET` names, and reports how many stay the same and
  which change (`Ryker.Evals.RoutingReplay`). The export holds what people
  said; keep it and the report outside the repository. With `--local-endpoint`
  and `--local-model` it asks a local routing model instead, the way routing's
  local comparison does, once per decision with no repair, and reports for
  each recorded action how often the local model kept it.

  `improvement-replay` asks recorded self-analyses again, each with today's
  instructions and contract, on the model `RYKER_EVAL_IMPROVEMENT_TARGET` names,
  and reports how many put the fault in the same place
  (`Ryker.Evals.ImprovementReplay`). Its runs hold what people said too.
  """

  use Mix.Task

  import Ecto.Query

  alias Ecto.Adapters.Postgres
  alias Ryker.Coop.Client
  alias Ryker.CoopFleet.Server, as: FleetServer

  alias Ryker.Evals.{
    CoopRunner,
    ImprovementReplay,
    Job,
    RoutingReplay,
    WorldCase,
    WorldCassette,
    WorldCoverage,
    WorldDatabase,
    WorldJudgeCase,
    WorldReport,
    WorldRunner,
    WorldSource,
    WorldSuite,
    WorldTools
  }

  alias Ryker.Evals.Runtime, as: EvalRuntime
  alias Ryker.Repo
  alias Ryker.Retention.Dispatcher, as: RetentionDispatcher
  alias Ryker.Work.Session, as: WorkSession

  @shortdoc "Exports or runs the versioned model-world scenarios"

  # Routing replay sessions at once, as the world shards run: one at a time,
  # the first replay of 139 decisions (2026-09-30) would have taken 80 minutes.
  @replay_concurrency 4

  @impl Mix.Task
  def run(["world-pack"]) do
    WorldCase.all()
    |> case do
      {:ok, cases} -> Enum.each(cases, &(WorldCase.document(&1) |> Jason.encode!() |> info()))
      {:error, reason} -> Mix.raise("could not compile model-world evals: #{inspect(reason)}")
    end
  end

  def run(["world" | arguments]) do
    run_world(arguments)
  end

  def run(["world-shards" | arguments]) do
    run_world_shards(arguments)
  end

  def run(["world-merge" | arguments]) do
    run_world_merge(arguments)
  end

  def run(["routing-replay" | arguments]) do
    run_routing_replay(arguments)
  end

  def run(["improvement-replay" | arguments]) do
    run_improvement_replay(arguments)
  end

  def run(_arguments) do
    Mix.raise(
      "usage: mix ryker.eval world-pack" <>
        " | world --results /absolute/world-results.json [--shard I/N]" <>
        " | world-shards --shards N" <>
        " | world-merge --results /absolute/world-results.json /absolute/shard.json..." <>
        " | routing-replay --examples /absolute/routing-examples.jsonl" <>
        " --results /absolute/routing-replay.json [--limit N] [--concurrency N]" <>
        " | improvement-replay --runs /absolute/analysis-runs.jsonl" <>
        " --results /absolute/improvement-replay.json [--concurrency N]"
    )
  end

  defp run_routing_replay(arguments) do
    case routing_replay_arguments(arguments) do
      {:ok, %{local_endpoint: endpoint} = replay} when is_binary(endpoint) ->
        run_local_routing_replay(replay)

      {:ok, replay} ->
        run_routing_replay_on_worker(replay)

      {:error, reason} ->
        Mix.raise("routing replay failed: #{inspect(reason)}")
    end
  end

  # A local model answers in seconds; two minutes is far past any answer seen.
  @local_routing_timeout_ms 120_000

  defp run_local_routing_replay(replay) do
    with {:ok, cases, skipped} <- RoutingReplay.cases(replay.examples, replay.limit),
         {:ok, finch} <- start_finch(),
         {:ok, result} <-
           RoutingReplay.run_local(cases, %{
             endpoint: replay.local_endpoint,
             model: replay.local_model,
             timeout_ms: @local_routing_timeout_ms,
             finch: finch
           }),
         summary = RoutingReplay.summary(cases, result, skipped),
         :ok <- File.write(replay.results, Jason.encode!(summary, pretty: true)) do
      info(
        "local routing replay: #{summary.same} of #{summary.total} decisions kept, " <>
          "#{summary.changed} changed, #{summary.not_answered} not usable, " <>
          "#{length(skipped)} examples skipped; report at #{replay.results}"
      )
    else
      {:error, reason} -> Mix.raise("routing replay failed: #{inspect(reason)}")
    end
  end

  defp run_routing_replay_on_worker(replay) do
    with {:ok, job} <- Job.routing(),
         {:ok, cases, skipped} <- RoutingReplay.cases(replay.examples, replay.limit),
         {:ok, finch} <- start_finch(),
         {:ok, client} <- eval_client(finch),
         {:ok, result} <-
           RoutingReplay.run(cases, client: client, concurrency: replay.concurrency, job: job),
         summary = RoutingReplay.summary(cases, result, skipped),
         :ok <- File.write(replay.results, Jason.encode!(summary, pretty: true)) do
      info(
        "routing replay: #{summary.same} of #{summary.total} decisions stayed the same, " <>
          "#{summary.changed} changed, #{summary.not_answered} not answered, " <>
          "#{length(skipped)} examples skipped; report at #{replay.results}"
      )
    else
      {:error, reason} -> Mix.raise("routing replay failed: #{inspect(reason)}")
    end
  end

  defp run_improvement_replay(arguments) do
    with {:ok, replay} <- improvement_replay_arguments(arguments),
         {:ok, job} <- Job.improvement(),
         {:ok, cases, skipped} <- ImprovementReplay.cases(replay.runs),
         {:ok, finch} <- start_finch(),
         {:ok, client} <- eval_client(finch),
         {:ok, result} <-
           ImprovementReplay.run(cases, client: client, concurrency: replay.concurrency, job: job),
         summary = ImprovementReplay.summary(cases, result, skipped),
         :ok <- File.write(replay.results, Jason.encode!(summary, pretty: true)) do
      info(
        "improvement replay: #{summary.same} of #{summary.total} diagnoses stayed the same, " <>
          "#{summary.changed} changed, #{summary.not_answered} not answered, " <>
          "#{length(skipped)} runs skipped; report at #{replay.results}"
      )
    else
      {:error, reason} -> Mix.raise("improvement replay failed: #{inspect(reason)}")
    end
  end

  defp improvement_replay_arguments(arguments) do
    case parse_flags(arguments, runs: :string, results: :string, concurrency: :integer) do
      {:ok, parsed, []} ->
        concurrency = parsed[:concurrency] || @replay_concurrency

        with runs when is_binary(runs) <- parsed[:runs],
             results when is_binary(results) <- parsed[:results],
             true <- Path.type(runs) == :absolute and Path.type(results) == :absolute,
             true <- concurrency in 1..16 do
          {:ok, %{runs: runs, results: results, concurrency: concurrency}}
        else
          _invalid -> {:error, :improvement_replay_needs_absolute_runs_and_results}
        end

      _invalid ->
        {:error, :invalid_arguments}
    end
  end

  defp routing_replay_arguments(arguments) do
    case parse_flags(arguments,
           examples: :string,
           results: :string,
           limit: :integer,
           concurrency: :integer,
           local_endpoint: :string,
           local_model: :string
         ) do
      {:ok, parsed, []} ->
        concurrency = parsed[:concurrency] || @replay_concurrency

        with examples when is_binary(examples) <- parsed[:examples],
             results when is_binary(results) <- parsed[:results],
             true <- Path.type(examples) == :absolute and Path.type(results) == :absolute,
             limit when is_nil(limit) or (is_integer(limit) and limit > 0) <- parsed[:limit],
             true <- concurrency in 1..16,
             true <- is_nil(parsed[:local_endpoint]) == is_nil(parsed[:local_model]) do
          {:ok,
           %{
             examples: examples,
             results: results,
             limit: limit,
             concurrency: concurrency,
             local_endpoint: parsed[:local_endpoint],
             local_model: parsed[:local_model]
           }}
        else
          _invalid -> {:error, :routing_replay_needs_absolute_examples_and_results}
        end

      _invalid ->
        {:error, :invalid_arguments}
    end
  end

  defp run_world(arguments) do
    with {:ok, world} <- world_arguments(arguments),
         %{results: results_path} <- world,
         :ok <- start_repo(),
         {:ok, eval_policies} <- Job.world(),
         :ok <- WorldDatabase.disposable_database(true),
         :ok <- baseline_configured(eval_policies, world.paired_baseline),
         :ok <- WorldCoverage.complete(),
         {:ok, runtime} <- EvalRuntime.world(),
         {:ok, finch} <- start_finch(),
         {:ok, eval_client} <- eval_client(finch),
         {:ok, cases} <- WorldCase.all(),
         {:ok, plan} <- WorldSuite.plan(cases, plan_options(world)),
         {:ok, plan} <- shard_plan(plan, world.shard),
         :ok <- stop_repo(),
         reports <- run_world_plan(plan, runtime, eval_policies, eval_client),
         {:ok, summary} <- world_summary(reports, world),
         :ok <- WorldReport.write(results_path, reports, summary: summary) do
      Enum.each(reports, &info(Jason.encode!(printable_world_report(&1))))
      announce_preserved_databases(reports)
      conclude_world(world, reports, summary)
    else
      {:error, {:invalid_shard, value}} ->
        Mix.raise(
          "world eval failed: --shard must be I/N, one 1-based shard of N (for example 2/4)," <>
            " got #{inspect(value)}"
        )

      {:error, reason} ->
        Mix.raise("world eval failed: #{inspect(reason)}")
    end
  end

  defp shard_plan(plan, nil), do: {:ok, plan}

  defp shard_plan(plan, {index, count}) do
    case WorldSuite.shard(plan, index, count) do
      {:ok, []} -> {:error, {:world_shard_empty, %{shard: index, of: count, plan: length(plan)}}}
      result -> result
    end
  end

  # A shard's results carry no verdict: its per-case rates would be over the
  # one or two repeats it happened to be dealt, and the paired comparison over
  # a fraction of the matrix. The thresholds are applied once, to the merge.
  defp world_summary(_reports, %{shard: {_index, _count}}), do: {:ok, nil}

  defp world_summary(reports, world),
    do: WorldSuite.summarize(reports, summary_options(world))

  defp conclude_world(%{shard: {index, count}}, reports, nil) do
    candidates = Enum.filter(reports, &(&1.lane == :candidate))
    passed = Enum.count(candidates, &(&1.status == :passed))

    info(
      "world shard #{index}/#{count}: #{passed}/#{length(candidates)} candidate observations" <>
        " passed; thresholds apply to the merged report"
    )
  end

  defp conclude_world(_world, _reports, summary), do: qualify_world(summary)

  defp qualify_world(summary) do
    info(Jason.encode!(%{"world_summary" => summary}))
    info("world evals: #{summary.candidate.passed}/#{summary.candidate.total} passed")

    unless summary.passed?,
      do: Mix.raise("model-world qualification failed: #{inspect(summary.failures)}")
  end

  defp run_world_shards(arguments) do
    with {:ok, shards} <- world_shards_arguments(arguments),
         {:ok, cases} <- WorldCase.all(),
         {:ok, plan} <- WorldSuite.plan(cases, plan_options(shards)) do
      for index <- 1..shards.shards,
          {:ok, observations} = WorldSuite.shard(plan, index, shards.shards),
          observations != [] do
        info(Jason.encode!(%{"observations" => length(observations), "shard" => index}))
      end
    else
      {:error, reason} -> Mix.raise("world shards failed: #{inspect(reason)}")
    end
  end

  defp run_world_merge(arguments) do
    with {:ok, merge} <- world_merge_arguments(arguments),
         {:ok, reports} <- read_partial_reports(merge.partials),
         {:ok, summary} <- WorldSuite.summarize(reports, summary_options(merge)),
         :ok <- WorldReport.write(merge.results, reports, summary: summary) do
      announce_preserved_databases(reports)
      qualify_world(summary)
    else
      {:error, reason} -> Mix.raise("world merge failed: #{inspect(reason)}")
    end
  end

  # Partial results are joined in plan order — scenario, repeat, then lane —
  # so the merged report reads exactly as one sequential run's would.
  defp read_partial_reports(partials) do
    Enum.reduce_while(partials, {:ok, []}, fn partial, {:ok, reports} ->
      case WorldReport.read(partial) do
        {:ok, read} -> {:cont, {:ok, reports ++ read}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reports} -> {:ok, Enum.sort_by(reports, &{&1.scenario_id, &1.repeat_index, &1.lane})}
      {:error, _reason} = error -> error
    end
  end

  defp run_world_plan(plan, runtime, eval_policies, eval_client) do
    template = Repo.config()[:database]

    run_world_plan(
      plan,
      &run_isolated_observation(&1, template, runtime, eval_policies, eval_client),
      fn observation, stopped ->
        unrun_report(
          observation,
          observation_policy(eval_policies, observation.lane),
          {:world_campaign_stopped,
           Map.take(stopped, [:scenario_id, :lane, :repeat_index, :status])}
        )
      end
    )
  end

  @doc false
  def run_world_plan(plan, run_observation, skip_observation) do
    # Only a harness fault stops the campaign. `:unrun` is the host saying the
    # observation never reached a model — an unconfigured environment, a
    # database that would not come up, a gateway that would not start — and
    # every later observation would fault the same way. A `:failed` observation
    # is the model result the thresholds exist to weigh, so it is collected and
    # the plan continues.
    {reports, _stopped} =
      Enum.map_reduce(plan, nil, fn
        observation, nil ->
          report = run_observation.(observation)
          {report, if(report.status == :unrun, do: report, else: nil)}

        observation, stopped ->
          {skip_observation.(observation, stopped), stopped}
      end)

    reports
  end

  defp run_isolated_observation(observation, template, runtime, eval_policies, eval_client) do
    observe = &run_world_observation_in_repo(&1, observation, runtime, eval_policies, eval_client)

    case run_world_observation_database(template, observe) do
      {:ok, report} ->
        report

      {:error, reason} ->
        unrun_report(observation, observation_policy(eval_policies, observation.lane), reason)
    end
  end

  @doc false
  def run_world_observation_database(template, observe) do
    # Every observation used to share the campaign's database, so a failure had
    # to stop the run to keep the next model off the failed case's surviving
    # custody. Each observation now gets its own copy of the migrated campaign
    # database: a pass drops it, and a failure keeps exactly its own rows under
    # the name the report carries.
    database = "#{template}_o#{System.unique_integer([:positive, :monotonic])}"

    case Postgres.storage_up(storage_config(database, template)) do
      :ok -> {:ok, preserved_or_dropped(observe.(database), database)}
      {:error, reason} -> {:error, {:world_eval_database_not_created, database, reason}}
    end
  end

  # `report.database` names the database that still holds this observation's
  # custody, and is nil once a passed observation's database has been dropped.
  defp preserved_or_dropped(%{status: :passed} = report, database) do
    case Postgres.storage_down(storage_config(database, nil)) do
      :ok -> Map.put(report, :database, nil)
      {:error, _reason} -> Map.put(report, :database, database)
    end
  end

  defp preserved_or_dropped(report, database), do: Map.put(report, :database, database)

  defp storage_config(database, template) do
    Keyword.merge(Repo.config(), database: database, template: template)
  end

  defp run_world_observation_in_repo(database, observation, runtime, eval_policies, eval_client) do
    case start_repo(database) do
      :ok ->
        try do
          run_world_observation(observation, runtime, eval_policies, eval_client)
        after
          stop_repo()
        end

      {:error, reason} ->
        unrun_report(observation, observation_policy(eval_policies, observation.lane), reason)
    end
  end

  defp announce_preserved_databases(reports) do
    reports
    |> Enum.filter(&Map.get(&1, :database))
    |> Enum.each(fn report ->
      info(
        "preserving failed world database #{report.database} for custody inspection" <>
          " (#{report.scenario_id} #{report.lane} repeat #{report.repeat_index})"
      )

      info("drop after inspection with: PGDATABASE=#{report.database} MIX_ENV=test mix ecto.drop")
    end)
  end

  defp run_world_observation(observation, runtime, eval_policies, eval_client) do
    policy = observation_policy(eval_policies, observation.lane)

    case run_world_case(
           observation.scenario,
           runtime,
           policy,
           eval_policies.judge,
           eval_client,
           observation
         ) do
      {:ok, report} -> observation_report(report, observation)
      {:error, {:world_eval_assertions, report}} -> observation_report(report, observation)
      {:error, reason} -> unrun_report(observation, policy, reason)
    end
  rescue
    error ->
      unrun_report(
        observation,
        observation_policy(eval_policies, observation.lane),
        {:world_eval_exception, Exception.message(error)}
      )
  catch
    kind, reason ->
      unrun_report(
        observation,
        observation_policy(eval_policies, observation.lane),
        {:world_eval_caught, kind, inspect(reason)}
      )
  end

  defp run_world_case(scenario, runtime, policy, judge_policy, eval_client, observation) do
    with {:ok, policy, repository_ref} <- world_source(scenario, policy, eval_client),
         {:ok, cassette} <- WorldCassette.start_link(scenario),
         {:ok, gateway} <- start_world_gateway(runtime, scenario, cassette) do
      try do
        eval_work = %{api: Client, client: %{eval_client | job: policy}}

        WorldRunner.run(scenario,
          api: eval_work.api,
          cassette: cassette,
          client: eval_work.client,
          cleanup: true,
          cleanup_remote: fn -> cleanup_world_sessions(eval_work, observation) end,
          expectation_mode: :model_world,
          judge: world_judge(eval_client, judge_policy),
          policy: policy.name,
          policy_digest: policy.digest,
          repository_ref: repository_ref,
          source_and_action_tools: gateway.source_and_action_tools,
          state_tools_endpoint: runtime.state_tools_endpoint,
          state_tools_secret: runtime.state_tools_secret,
          tool_catalog_sha256: gateway.tool_catalog_sha256,
          tool_names: gateway.tool_names,
          worker_ref: "model-world:#{observation.lane}:#{scenario.id}:#{observation.repeat_index}"
        )
      after
        Supervisor.stop(gateway.supervisor)
        GenServer.stop(cassette)
      end
    end
  end

  # A scenario's captured repository is its Work session's read-only checkout, staged in the
  # eval Coop's own state beside its socket (`Ryker.Evals.WorldSource`). Without it Work has no
  # configured repository, and a scenario about an engineering task can only be asked to connect
  # one (rivals-engineering-task-offer, 2026-09-30).
  defp world_source(scenario, policy, eval_client) do
    case WorldCase.fixture_context(scenario) do
      {:ok, []} ->
        {:ok, policy, nil}

      {:ok, [capture]} ->
        {:ok, at, 0} = DateTime.from_iso8601(scenario.clock["start"])

        with {:ok, source} <-
               WorldSource.stage(capture, Path.dirname(eval_client.socket), at),
             {:ok, sourced} <- Job.with_source(policy, source),
             do: {:ok, sourced, capture["repository"]}

      {:ok, _several} ->
        {:error, :world_scenario_has_several_repositories}

      {:error, _reason} = error ->
        error
    end
  end

  defp observation_policy(eval_policies, :candidate), do: eval_policies.subject
  defp observation_policy(eval_policies, :baseline), do: eval_policies.baseline

  defp observation_report(report, observation) do
    Map.merge(report, %{lane: observation.lane, repeat_index: observation.repeat_index})
  end

  defp unrun_report(observation, policy, reason) do
    %{
      database: nil,
      deliveries: [],
      episode_id: nil,
      failures: [],
      lane: observation.lane,
      quality: %{reason: inspect(reason), status: :unrun},
      record_history: [],
      records: [],
      repeat_index: observation.repeat_index,
      runtime: %{
        policy: policy.name,
        policy_digest: policy.digest,
        tool_catalog_sha256: observation.scenario.tool_catalog_digest,
        turns: []
      },
      scenario_id: observation.scenario.id,
      source_calls: [],
      status: :unrun,
      turn_id: nil,
      turn_ids: []
    }
  end

  defp world_judge(judge_client, judge_policy) do
    fn scenario, report ->
      with {:ok, judge} <- WorldJudgeCase.new(scenario, report) do
        result =
          CoopRunner.run_case(judge,
            client: judge_client,
            job: judge_policy
          )

        {:ok, result}
      end
    end
  end

  defp start_world_gateway(runtime, scenario, cassette) do
    with {:ok, prepared} <- WorldTools.prepare(runtime.state_tools, scenario, cassette),
         child = {FleetServer, Map.put(runtime.gateway, :state_tools, prepared.state_tools)},
         {:ok, supervisor} <- Supervisor.start_link([child], strategy: :one_for_one) do
      {:ok,
       %{
         supervisor: supervisor,
         source_and_action_tools: prepared.source_and_action_tools,
         tool_catalog_sha256: prepared.catalog_sha256,
         tool_names: prepared.tool_names
       }}
    end
  end

  defp eval_client(finch) do
    with {:ok, socket} <- Job.socket() do
      Client.new(
        finch: finch,
        receive_timeout: EvalRuntime.receive_timeout_ms(),
        socket: socket
      )
    end
  end

  defp start_repo do
    case Process.whereis(Ryker.Repo) do
      nil ->
        start_repo_after_apps(Application.ensure_all_started(:ecto_sql))

      _pid ->
        :ok
    end
  end

  defp start_repo_after_apps({:ok, _apps}) do
    case Ryker.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp start_repo_after_apps({:error, _reason} = error), do: error

  defp start_repo(database) do
    case Repo.start_link(database: database) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, {:world_eval_repo_not_started, database, reason}}
    end
  end

  defp stop_repo do
    case Process.whereis(Repo) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  defp printable_world_report(report) do
    {:ok, result} = WorldReport.result(report)
    result
  end

  # The plan flags say what runs and belong to every shard; the threshold flags
  # qualify one report and belong to the merge. --paired-baseline is both: it
  # adds the baseline lane to the plan and the paired comparison to the summary.
  @plan_flags [{:case, :string}, paired_baseline: :boolean, repeat: :integer, tag: :string]
  @threshold_flags [
    max_paired_regression: :float,
    min_case_pass_rate: :float,
    min_overall_pass_rate: :float,
    paired_baseline: :boolean
  ]

  defp world_arguments(arguments) do
    strict = Keyword.merge(@plan_flags, @threshold_flags) ++ [results: :string, shard: :string]

    with {:ok, parsed, []} <- parse_flags(arguments, strict),
         {:ok, shard} <- parse_shard(Keyword.get(parsed, :shard)) do
      prepare_world_arguments(parsed, shard)
    else
      {:ok, _parsed, _positional} -> {:error, :invalid_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp world_shards_arguments(arguments) do
    with {:ok, parsed, []} <- parse_flags(arguments, @plan_flags ++ [shards: :integer]),
         shards when is_integer(shards) and shards >= 1 <- Keyword.get(parsed, :shards),
         plan = plan_options(parsed),
         {:ok, _plan} <- WorldSuite.plan([argument_case(plan)], plan) do
      {:ok, Map.put(plan, :shards, shards)}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp world_merge_arguments(arguments) do
    with {:ok, parsed, partials} <- parse_flags(arguments, @threshold_flags ++ [results: :string]),
         true <- partials != [] and Enum.all?(partials, &absolute_reference?/1),
         merge = merge_settings(parsed, partials),
         true <- absolute_reference?(merge.results),
         {:ok, _summary} <- WorldSuite.summarize(argument_reports(merge), summary_options(merge)) do
      {:ok, merge}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp merge_settings(parsed, partials) do
    parsed
    |> threshold_settings()
    |> Map.merge(%{partials: partials, results: Keyword.get(parsed, :results)})
  end

  defp threshold_settings(parsed) do
    %{
      max_paired_regression: Keyword.get(parsed, :max_paired_regression, 0.1),
      min_case_pass_rate: Keyword.get(parsed, :min_case_pass_rate, 2 / 3),
      min_overall_pass_rate: Keyword.get(parsed, :min_overall_pass_rate, 0.9),
      paired_baseline: Keyword.get(parsed, :paired_baseline, false)
    }
  end

  defp parse_flags(arguments, strict) do
    if duplicate_world_flags?(arguments) do
      {:error, :invalid_arguments}
    else
      case OptionParser.parse(arguments, strict: strict) do
        {parsed, positional, []} -> {:ok, parsed, positional}
        _invalid -> {:error, :invalid_arguments}
      end
    end
  end

  defp parse_shard(nil), do: {:ok, nil}

  defp parse_shard(value) do
    with true <- Regex.match?(~r{\A[0-9]+/[0-9]+\z}, value),
         [index, count] <- value |> String.split("/") |> Enum.map(&String.to_integer/1),
         true <- count >= 1 and index in 1..count do
      {:ok, {index, count}}
    else
      _invalid -> {:error, {:invalid_shard, value}}
    end
  end

  defp duplicate_world_flags?(arguments) do
    flags =
      arguments
      |> Enum.filter(&String.starts_with?(&1, "--"))
      |> Enum.map(fn flag -> flag |> String.split("=", parts: 2) |> hd() end)

    Enum.uniq(flags) != flags
  end

  defp prepare_world_arguments(parsed, shard) do
    if Enum.uniq(Keyword.keys(parsed)) == Keyword.keys(parsed) do
      world =
        parsed
        |> plan_options()
        |> Map.merge(threshold_settings(parsed))
        |> Map.merge(%{results: Keyword.get(parsed, :results), shard: shard})

      validate_world_arguments(world)
    else
      {:error, :invalid_arguments}
    end
  end

  defp validate_world_arguments(world) do
    with true <- absolute_reference?(world.results),
         {:ok, _plan} <- WorldSuite.plan([argument_case(world)], plan_options(world)),
         {:ok, _summary} <-
           WorldSuite.summarize(argument_reports(world), summary_options(world)) do
      {:ok, world}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp argument_case(world) do
    scenario_id = world.scenario_id || "argument-case"
    tags = if world.tag, do: [world.tag], else: ["argument-tag"]

    %WorldCase{
      actors: [],
      clock: %{},
      events: [],
      expect: %{},
      host_replay: %{},
      id: scenario_id,
      path: "argument-case",
      provenance: %{},
      tags: tags,
      tool_catalog: %{},
      tool_catalog_digest: String.duplicate("0", 64),
      world: %{}
    }
  end

  defp argument_reports(%{paired_baseline: true}),
    do: [argument_report(:baseline), argument_report(:candidate)]

  defp argument_reports(%{paired_baseline: false}), do: [argument_report(:candidate)]

  defp argument_report(lane) do
    %{
      failures: [],
      lane: lane,
      repeat_index: 1,
      scenario_id: "argument-case",
      status: :passed
    }
  end

  defp absolute_reference?(value) when is_binary(value) and value != "",
    do: Path.type(value) == :absolute

  defp absolute_reference?(_value), do: false

  defp plan_options(parsed) when is_list(parsed) do
    %{
      paired_baseline: Keyword.get(parsed, :paired_baseline, false),
      repeat: Keyword.get(parsed, :repeat, 3),
      scenario_id: Keyword.get(parsed, :case),
      tag: Keyword.get(parsed, :tag)
    }
  end

  defp plan_options(world) do
    %{
      paired_baseline: world.paired_baseline,
      repeat: world.repeat,
      scenario_id: world.scenario_id,
      tag: world.tag
    }
  end

  defp summary_options(world) do
    %{
      max_paired_regression: world.max_paired_regression,
      min_case_pass_rate: world.min_case_pass_rate,
      min_overall_pass_rate: world.min_overall_pass_rate,
      paired_baseline: world.paired_baseline
    }
  end

  defp baseline_configured(%{baseline: nil}, true),
    do: {:error, :world_baseline_target_not_configured}

  defp baseline_configured(_policies, _paired), do: :ok

  defp cleanup_world_sessions(work, observation) do
    options = [
      api: work.api,
      client: work.client,
      closed_session_grace_seconds: 0,
      lease_seconds: 60,
      max_attempts: 1,
      retry_base_seconds: 1,
      retry_max_seconds: 1,
      worker_ref:
        "model-world-cleanup:#{observation.lane}:#{observation.scenario.id}:#{observation.repeat_index}"
    ]

    with :ok <- WorldDatabase.terminalize_waiting_episodes() do
      drain_world_cleanup(options, 16)
    end
  end

  defp drain_world_cleanup(_options, 0), do: {:error, :world_cleanup_did_not_drain}

  defp drain_world_cleanup(options, left) do
    case RetentionDispatcher.run_once(options) do
      {:ok, :idle} -> world_sessions_discarded()
      {:ok, {:executed, _execution}} -> drain_world_cleanup(options, left - 1)
      {:ok, {:deferred, reason}} -> {:error, {:world_cleanup_deferred, reason}}
      {:ok, {:blocked, reason}} -> {:error, {:world_cleanup_blocked, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp world_sessions_discarded do
    pending =
      Repo.aggregate(
        from(session in WorkSession, where: session.cleanup_status != :discarded),
        :count
      )

    if pending == 0,
      do: :ok,
      else: {:error, {:world_cleanup_incomplete, pending}}
  end

  defp start_finch do
    Application.ensure_all_started(:finch)

    case Process.whereis(Ryker.EvalFinch) do
      nil ->
        case Finch.start_link(name: Ryker.EvalFinch) do
          {:ok, _pid} -> {:ok, Ryker.EvalFinch}
          {:error, {:already_started, _pid}} -> {:ok, Ryker.EvalFinch}
          {:error, reason} -> {:error, {:finch_start_failed, reason}}
        end

      _pid ->
        {:ok, Ryker.EvalFinch}
    end
  end

  defp info(message), do: Mix.shell().info(message)
end
