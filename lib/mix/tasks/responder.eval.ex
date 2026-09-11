defmodule Mix.Tasks.Responder.Eval do
  @moduledoc """
  Exports or executes the recorded Elixir admission and Work model corpora.

      mix responder.eval admission-pack
      mix responder.eval admission
      mix responder.eval work-pack
      mix responder.eval work
      mix responder.eval world-pack
      mix responder.eval world --results /absolute/world-results.json

  A `*-pack` command emits one JSON object per case without calling a model.
  The live commands run the same sanitized cases through the dedicated
  evaluation policies named by the evaluation environment
  (`RESPONDER_EVAL_SOCKET`, `RESPONDER_EVAL_NO_TOOLS_POLICY`,
  `RESPONDER_EVAL_WORLD_POLICY` and their `_DIGEST` companions). Admission and
  narrow Work evals use the no-tools policy; fabricated-world evals use a
  separate sandbox-only policy. Eval authority is supplied explicitly and is
  refused if it matches a reviewed production policy binding, so an evaluation
  cannot inherit production repository or mutation authority.
  """

  use Mix.Task

  import Ecto.Query

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

  def run(_arguments) do
    Mix.raise(
      "usage: mix responder.eval admission-pack | work-pack | world-pack | admission | work | world --results /absolute/world-results.json"
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
         reports <- run_world_plan(plan, runtime, eval_policies, eval_client),
         {:ok, summary} <- WorldSuite.summarize(reports, summary_options(world)),
         :ok <- WorldReport.write(results_path, reports, summary: summary) do
      Enum.each(reports, &info(Jason.encode!(printable_world_report(&1))))
      info(Jason.encode!(%{"world_summary" => summary}))
      info("world evals: #{summary.candidate.passed}/#{summary.candidate.total} passed")

      unless summary.passed?,
        do: Mix.raise("model-world qualification failed: #{inspect(summary.failures)}")
    else
      {:error, reason} -> Mix.raise("world eval failed: #{inspect(reason)}")
    end
  end

  defp run_world_plan(plan, runtime, eval_policies, eval_client) do
    run_world_plan(
      plan,
      &run_world_observation(&1, runtime, eval_policies, eval_client),
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
    {reports, _stopped} =
      Enum.map_reduce(plan, nil, fn
        observation, nil ->
          report = run_observation.(observation)
          {report, if(report.status == :passed, do: nil, else: report)}

        observation, stopped ->
          {skip_observation.(observation, stopped), stopped}
      end)

    reports
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

  defp printable_world_report(report) do
    {:ok, result} = WorldReport.result(report)
    result
  end

  defp world_arguments(arguments) do
    strict = [
      {:case, :string},
      max_paired_regression: :float,
      min_case_pass_rate: :float,
      min_overall_pass_rate: :float,
      paired_baseline: :boolean,
      repeat: :integer,
      results: :string,
      tag: :string
    ]

    if duplicate_world_flags?(arguments) do
      {:error, :invalid_arguments}
    else
      case OptionParser.parse(arguments, strict: strict) do
        {parsed, [], []} -> prepare_world_arguments(parsed)
        _invalid -> {:error, :invalid_arguments}
      end
    end
  end

  defp duplicate_world_flags?(arguments) do
    flags =
      arguments
      |> Enum.filter(&String.starts_with?(&1, "--"))
      |> Enum.map(fn flag -> flag |> String.split("=", parts: 2) |> hd() end)

    Enum.uniq(flags) != flags
  end

  defp prepare_world_arguments(parsed) do
    if Enum.uniq(Keyword.keys(parsed)) == Keyword.keys(parsed) do
      world = %{
        max_paired_regression: Keyword.get(parsed, :max_paired_regression, 0.1),
        min_case_pass_rate: Keyword.get(parsed, :min_case_pass_rate, 2 / 3),
        min_overall_pass_rate: Keyword.get(parsed, :min_overall_pass_rate, 0.9),
        paired_baseline: Keyword.get(parsed, :paired_baseline, false),
        repeat: Keyword.get(parsed, :repeat, 3),
        results: Keyword.get(parsed, :results),
        scenario_id: Keyword.get(parsed, :case),
        tag: Keyword.get(parsed, :tag)
      }

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
