defmodule Ryker.Evals.WorldRunner do
  @moduledoc """
  Runs one model-world scenario through the real episode, Work, state-record,
  validation, and delivery boundaries.

  The runner never contacts a platform publisher. Visible output is settled by
  an evaluation-only adapter, while Coop and the production Ryker state
  tools remain real. Callers provide an isolated database and Coop policy.

  The runner owns the settings and the run's shape; `WorldInputs` prepares
  the scenario's inputs, `WorldDriver` executes them, `WorldEvidence` builds
  the report, `WorldAssertions` checks it, and `WorldDatabase` guards the
  disposable database around the whole run.
  """

  alias Ryker.Evals.{
    WorldAssertions,
    WorldCase,
    WorldDatabase,
    WorldDriver,
    WorldEvidence,
    WorldInputs
  }

  alias Ryker.Repo

  @fields [
    :api,
    :before_execute,
    :before_wait_wakeup,
    :cassette,
    :client,
    :cleanup,
    :cleanup_remote,
    :expectation_mode,
    :id_generator,
    :judge,
    :policy,
    :policy_digest,
    :source_and_action_tools,
    :state_tools_endpoint,
    :state_tools_secret,
    :tool_catalog_sha256,
    :tool_names,
    :worker_ref
  ]

  @spec run(WorldCase.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def run(%WorldCase{} = scenario, options) do
    with {:ok, settings} <- settings(options),
         {:ok, delivery_agent} <- Agent.start_link(fn -> WorldInputs.delivery_state(scenario) end) do
      try do
        execute(scenario, settings, delivery_agent)
      after
        Agent.stop(delivery_agent)
      end
    end
  end

  def run(_scenario, _options), do: {:error, {:invalid_world_runner, :scenario}}

  defp execute(scenario, settings, delivery_agent) do
    with {:ok, inputs} <- WorldInputs.input_events(scenario),
         :ok <- WorldDatabase.disposable_database(settings.cleanup),
         identity <- settings.id_generator.(),
         :ok <- reference(identity, :identity) do
      scenario
      |> execute_without_cleanup(inputs, identity, settings, delivery_agent)
      |> WorldEvidence.retain_failure_report(scenario, identity, settings, delivery_agent)
      |> WorldDatabase.finish_execution(settings)
    end
  end

  defp execute_without_cleanup(scenario, inputs, identity, settings, delivery_agent) do
    settings =
      if is_nil(settings.source_and_action_tools) do
        %{settings | source_and_action_tools: WorldCase.fabricated_tools(scenario)}
      else
        settings
      end

    world_started_at = Repo.now!()

    with {:ok, adapters} <- WorldInputs.eval_adapters(delivery_agent),
         :ok <- WorldInputs.join_scenario_channels(inputs, world_started_at),
         {:ok, executions, skipped} <-
           WorldDriver.execute_inputs(
             inputs,
             scenario,
             settings,
             adapters,
             identity,
             world_started_at
           ),
         {:ok, report} <- assess(scenario, executions, delivery_agent, settings, skipped) do
      {:ok, report}
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:world_eval_runner_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:world_eval_runner_caught, kind, inspect(reason)}}
  end

  defp assess(scenario, executions, delivery_agent, settings, skipped) do
    report = WorldEvidence.report_data(scenario, executions, delivery_agent, settings, skipped)
    failures = WorldAssertions.failures(scenario, report, executions, settings.expectation_mode)
    report = %{report | failures: failures, status: if(failures == [], do: :unrun, else: :failed)}

    cond do
      failures != [] -> {:error, {:world_eval_assertions, report}}
      is_nil(settings.judge) -> {:ok, report}
      true -> WorldEvidence.apply_judgment(settings.judge.(scenario, report), report)
    end
  end

  defp settings(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> settings(),
      else: {:error, {:invalid_world_runner, :options}}
  end

  defp settings(%{} = options) do
    if Map.keys(options) -- @fields == [] do
      options |> prepare_settings() |> validate_settings()
    else
      {:error, {:invalid_world_runner, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_world_runner, :options}}

  defp prepare_settings(options) do
    %{
      api: Map.get(options, :api, Ryker.Coop.Client),
      before_execute: Map.get(options, :before_execute, fn _claim, _scenario -> :ok end),
      before_wait_wakeup: Map.get(options, :before_wait_wakeup, fn _episode, _record -> :ok end),
      cassette: Map.get(options, :cassette),
      client: Map.get(options, :client),
      cleanup: Map.get(options, :cleanup, false),
      cleanup_remote: Map.get(options, :cleanup_remote, fn -> :ok end),
      expectation_mode: Map.get(options, :expectation_mode, :host_replay),
      id_generator: Map.get(options, :id_generator, &Ecto.UUID.generate/0),
      judge: Map.get(options, :judge),
      policy: Map.get(options, :policy),
      policy_digest: Map.get(options, :policy_digest),
      source_and_action_tools: Map.get(options, :source_and_action_tools),
      state_tools_endpoint: Map.get(options, :state_tools_endpoint),
      state_tools_secret: Map.get(options, :state_tools_secret),
      tool_catalog_sha256: Map.get(options, :tool_catalog_sha256),
      tool_names: Map.get(options, :tool_names),
      worker_ref: Map.get(options, :worker_ref, "world-eval")
    }
  end

  defp validate_settings(settings) do
    checks = [
      is_atom(settings.api),
      not is_nil(settings.client),
      is_function(settings.before_execute, 2),
      is_function(settings.before_wait_wakeup, 2),
      is_boolean(settings.cleanup),
      is_function(settings.cleanup_remote, 0),
      settings.expectation_mode in [:host_replay, :model_world],
      is_function(settings.id_generator, 0),
      is_nil(settings.judge) or is_function(settings.judge, 2),
      reference(settings.policy, :policy) == :ok,
      digest?(settings.policy_digest),
      is_nil(settings.source_and_action_tools) or
        valid_source_and_action_tools?(settings.source_and_action_tools),
      reference(settings.state_tools_endpoint, :state_tools_endpoint) == :ok,
      reference(settings.state_tools_secret, :state_tools_secret) == :ok,
      is_nil(settings.tool_catalog_sha256) or digest?(settings.tool_catalog_sha256),
      is_nil(settings.tool_names) or valid_tool_names?(settings.tool_names),
      reference(settings.worker_ref, :worker_ref) == :ok
    ]

    if Enum.all?(checks),
      do: {:ok, settings},
      else: {:error, {:invalid_world_runner, :options}}
  end

  defp reference(value, _field) when is_binary(value) and byte_size(value) in 1..2_048 do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, :reference}
  end

  defp reference(_value, field), do: {:error, field}

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_tool_names?(names) when is_list(names),
    do: names == Enum.uniq(names) and Enum.all?(names, &(reference(&1, :tool_name) == :ok))

  defp valid_tool_names?(_names), do: false

  defp valid_source_and_action_tools?(tools) when is_list(tools) do
    names =
      Enum.map(tools, fn
        %{"name" => name} when is_binary(name) -> name
        name when is_binary(name) -> name
        _invalid -> nil
      end)

    Enum.all?(names, &is_binary/1) and names == Enum.uniq(names)
  end

  defp valid_source_and_action_tools?(_tools), do: false
end
