defmodule Mix.Tasks.Responder.Eval do
  @moduledoc """
  Exports or executes the recorded Elixir admission and Work model corpora.

      mix responder.eval admission-pack
      mix responder.eval admission
      mix responder.eval work-pack
      mix responder.eval work
      mix responder.eval world-pack
      mix responder.eval world --results /absolute/world-results.json
      mix responder.eval world --results /absolute/shard-2.json --shard 2/4
      mix responder.eval world-shards --shards 4
      mix responder.eval world-merge --results /absolute/world-results.json \\
        /absolute/shard-1.json /absolute/shard-2.json

  A `*-pack` command emits one JSON object per case without calling a model.
  The live commands run the same sanitized cases through the dedicated
  evaluation policies named by the evaluation environment
  (`RESPONDER_EVAL_SOCKET`, `RESPONDER_EVAL_NO_TOOLS_POLICY`,
  `RESPONDER_EVAL_WORLD_POLICY` and their `_DIGEST` companions). Admission and
  narrow Work evals use the no-tools policy; fabricated-world evals use a
  separate sandbox-only policy. Eval authority is supplied explicitly and is
  refused if it matches a reviewed production policy binding, so an evaluation
  cannot inherit production repository or mutation authority.

  A world matrix is 31 scenarios × 3 repeats × 2 lanes at about 93 seconds an
  observation, so `scripts/elixir-world-eval.sh` runs it as shards: separate
  VMs, each on its own campaign database and listener ports, each running the
  slice `--shard I/N` deals it from the same ordered plan and writing results
  without a verdict. `world-shards` previews which shards a plan fills so no
  empty VM is started, and `world-merge` joins the partial results into the
  one report the thresholds and the trend tooling read.
  """

  use Mix.Task

  import Ecto.Query

  alias Ecto.Adapters.Postgres
  alias Responder.Coop.Client
  alias Responder.CoopFleet.Server, as: FleetServer

  alias Responder.Evals.{
    AdmissionCase,
    CoopRunner,
    Policy,
    WorkCase,
    WorldCase,
    WorldCassette,
    WorldCoverage,
    WorldJudgeCase,
    WorldReport,
    WorldRunner,
    WorldSuite,
    WorldTools
  }

  alias Responder.Evals.Runtime, as: EvalRuntime
  alias Responder.Repo
  alias Responder.Retention.Dispatcher, as: RetentionDispatcher
  alias Responder.Work.Session, as: WorkSession

  @shortdoc "Exports or runs the recorded Elixir model eval corpora"

  @impl Mix.Task
  def run(["admission-pack"]) do
    AdmissionCase.all()
    |> case do
      {:ok, cases} -> Enum.each(cases, &(AdmissionCase.document(&1) |> Jason.encode!() |> info()))
      {:error, reason} -> Mix.raise("could not compile admission evals: #{inspect(reason)}")
    end
  end

  def run(["work-pack"]) do
    WorkCase.all()
    |> case do
      {:ok, cases} -> Enum.each(cases, &(WorkCase.document(&1) |> Jason.encode!() |> info()))
      {:error, reason} -> Mix.raise("could not compile Work evals: #{inspect(reason)}")
    end
  end

  def run(["world-pack"]) do
    WorldCase.all()
    |> case do
      {:ok, cases} -> Enum.each(cases, &(WorldCase.document(&1) |> Jason.encode!() |> info()))
      {:error, reason} -> Mix.raise("could not compile model-world evals: #{inspect(reason)}")
    end
  end

  def run(["admission" | arguments]) do
    run_live(:admission, arguments)
  end

  def run(["work" | arguments]) do
    run_live(:work, arguments)
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

  def run(_arguments) do
    Mix.raise(
      "usage: mix responder.eval admission-pack | work-pack | world-pack | admission | work" <>
        " | world --results /absolute/world-results.json [--shard I/N]" <>
        " | world-shards --shards N" <>
        " | world-merge --results /absolute/world-results.json /absolute/shard.json..."
    )
  end

  defp run_live(kind, arguments) do
    with :ok <- no_arguments(arguments),
         {:ok, %{subject: eval_policy}} <- Policy.for_kind(kind),
         {:ok, cases} <- eval_cases(kind),
         {:ok, finch} <- start_finch(),
         {:ok, client} <- eval_client(finch),
         {:ok, report} <-
           CoopRunner.run(cases,
             client: client,
             policy: eval_policy.name,
             policy_digest: eval_policy.digest
           ) do
      Enum.each(report.results, &info(Jason.encode!(printable_result(&1))))
      info("#{kind} evals: #{report.passed}/#{report.total} passed")

      if report.failed > 0,
        do: Mix.raise("#{report.failed} #{kind} model eval(s) failed")
    else
      {:error, reason} -> Mix.raise("#{kind} eval failed: #{inspect(reason)}")
    end
  end

  defp eval_cases(:admission), do: AdmissionCase.all()
  defp eval_cases(:work), do: WorkCase.all()

  defp run_world(arguments) do
    with {:ok, world} <- world_arguments(arguments),
         %{results: results_path} <- world,
         :ok <- start_repo(),
         {:ok, eval_policies} <- Policy.for_kind(:world),
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
    with {:ok, cassette} <- WorldCassette.start_link(scenario),
         {:ok, gateway} <- start_world_gateway(runtime, scenario, cassette) do
      try do
        eval_work = %{api: Client, client: eval_client}

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
            policy: judge_policy.name,
            policy_digest: judge_policy.digest
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
    with {:ok, socket} <- Policy.socket() do
      Client.new(
        finch: finch,
        receive_timeout: EvalRuntime.receive_timeout_ms(),
        socket: socket
      )
    end
  end

  defp no_arguments([]), do: :ok
  defp no_arguments(_arguments), do: {:error, :invalid_arguments}

  defp start_repo do
    case Process.whereis(Responder.Repo) do
      nil ->
        start_repo_after_apps(Application.ensure_all_started(:ecto_sql))

      _pid ->
        :ok
    end
  end

  defp start_repo_after_apps({:ok, _apps}) do
    case Responder.Repo.start_link() do
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
    do: {:error, :world_baseline_policy_not_configured}

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

    with :ok <- WorldRunner.terminalize_waiting_episodes() do
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

    case Process.whereis(Responder.EvalFinch) do
      nil ->
        case Finch.start_link(name: Responder.EvalFinch) do
          {:ok, _pid} -> {:ok, Responder.EvalFinch}
          {:error, {:already_started, _pid}} -> {:ok, Responder.EvalFinch}
          {:error, reason} -> {:error, {:finch_start_failed, reason}}
        end

      _pid ->
        {:ok, Responder.EvalFinch}
    end
  end

  defp printable_result(result) do
    %{
      "decision" => result.decision,
      "eval_id" => result.eval_id,
      "reason" => result.reason && inspect(result.reason),
      "session_id" => result[:session_id],
      "status" => Atom.to_string(result.status),
      "turn_id" => result[:turn_id]
    }
  end

  defp info(message), do: Mix.shell().info(message)
end
