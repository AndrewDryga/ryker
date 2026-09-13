defmodule Responder.Runtime.Owner do
  @moduledoc """
  Reconciles the running children with the latest durable settings revision.

  One process owns this. It reads the saved revision, assembles the runtime
  bindings, starts or replaces exactly the children whose configuration
  changed, and only then records the application result against that exact
  revision — so a crash between Save and apply is recovered by the next
  reconcile, and an older apply result can never overwrite a newer save.

  An installation with no settings is not a failure: the local console still
  runs so setup is reachable, and nothing that needs a policy or a credential
  starts. A database that cannot be read is a failure and is retried; it never
  becomes an empty configuration.
  """

  use GenServer
  require Logger

  alias Responder.{Bootstrap, Settings}
  alias Responder.ControlPlane.SlackNames
  alias Responder.Runtime.Assembly
  alias Responder.Slack.Client

  @retry_ms 5_000
  # Started and replaced by this owner, in dependency order.
  @children [
    {:coop_worker_gateway, Responder.CoopFleet.Server},
    {:state_tools, Responder.StateTools.Server},
    {:admission, Responder.Admission.Runtime},
    {:work, Responder.Work.Runtime},
    {:learning, Responder.Learning.Runtime},
    {:retention, Responder.Retention.Runtime},
    {:github, Responder.GitHub.Runtime},
    {:publication, Responder.Publication.Runtime},
    {:delivery, Responder.Delivery.Runtime},
    {:emisar, Responder.Emisar.ApprovalRuntime},
    {:event_waits, Responder.State.EventWaitWorker},
    {:schedules, Responder.State.ScheduleRuntime},
    {:slack, Responder.Slack.Runtime},
    {:webhooks, Responder.Webhooks.Server},
    {:control_plane, Responder.ControlPlane.Server}
  ]
  @control_plane_companions [Responder.ControlPlane.Updates, SlackNames]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}
  end

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "Applies the latest saved revision now and reports what happened."
  @spec reconcile(GenServer.server()) ::
          {:ok, :applied | :unchanged | :not_initialized}
          | {:error, :settings_unavailable | term()}
  def reconcile(owner \\ __MODULE__), do: GenServer.call(owner, :reconcile, 30_000)

  @doc "The revision currently running, or nil on a fresh installation."
  @spec applied_revision(GenServer.server()) :: non_neg_integer() | nil
  def applied_revision(owner \\ __MODULE__), do: GenServer.call(owner, :applied_revision)

  @doc """
  The configuration keys whose child is running right now.

  Readiness asks the owner rather than pattern-matching supervisor children:
  several of them are plain listeners whose module is the web server's, so the
  child itself cannot say which setting started it.
  """
  @spec running_keys(GenServer.server()) :: [atom()]
  def running_keys(owner \\ __MODULE__) do
    GenServer.call(owner, :running_keys)
  catch
    :exit, _reason -> []
  end

  @impl true
  def init(options) do
    state = %{
      bootstrap: Keyword.get_lazy(options, :bootstrap, &bootstrap/0),
      csrf_secret: :crypto.strong_rand_bytes(32),
      revision: nil,
      supervisor: Keyword.get(options, :supervisor, Responder.Runtime.Supervisor),
      running: %{}
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    {_result, state} = apply_latest(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    {result, state} = apply_latest(state)
    {:reply, result, state}
  end

  def handle_call(:applied_revision, _from, state), do: {:reply, state.revision, state}

  def handle_call(:running_keys, _from, state) do
    keys =
      state.running
      |> Enum.filter(fn {_key, %{pids: pids}} -> Enum.any?(pids, &Process.alive?/1) end)
      |> Enum.map(&elem(&1, 0))

    {:reply, keys, state}
  end

  @impl true
  def handle_info(:retry, state) do
    {_result, state} = apply_latest(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_latest(state) do
    case read_settings() do
      {:ok, :not_initialized} -> apply_fresh_setup(state)
      {:ok, settings} -> apply_settings(state, settings)
      {:error, reason} -> retry(state, reason)
    end
  end

  # Setup must be reachable before any product configuration exists, so the
  # console runs from bootstrap alone and nothing else starts.
  defp apply_fresh_setup(state) do
    state = reconcile_children(state, %{control_plane: console(state, nil, %{})})
    {{:ok, :not_initialized}, %{state | revision: nil}}
  end

  defp apply_settings(state, settings) do
    revision = settings.installation.revision

    if revision == state.revision do
      {{:ok, :unchanged}, state}
    else
      case Assembly.build(state.bootstrap, settings) do
        {:ok, configuration} ->
          # Publish before starting anything. A child that reads another
          # runtime's published configuration in `init` — the Slack name cache
          # does — otherwise starts against the previous value and declines with
          # `:ignore`, which is permanent: nothing restarts a runtime whose own
          # configuration never changed again.
          Assembly.publish(configuration)
          state = reconcile_children(state, applied_children(state, configuration))
          record(revision, :ok)
          {{:ok, :applied}, %{state | revision: revision}}

        {:error, reason} ->
          # The saved revision stays saved and visibly unapplied; the running
          # children keep the last configuration that actually assembled.
          Logger.warning("settings revision #{revision} could not be applied: #{inspect(reason)}")
          record(revision, {:error, :assembly_failed})
          {{:error, reason}, state}
      end
    end
  end

  defp applied_children(state, configuration) do
    Map.new(@children, fn {key, _module} ->
      {key, child_configuration(state, key, configuration)}
    end)
    |> Enum.reject(fn {_key, configuration} -> is_nil(configuration) end)
    |> Map.new()
  end

  defp child_configuration(state, :control_plane, configuration) do
    console(state, configuration[:control_plane], configuration)
  end

  defp child_configuration(_state, key, configuration), do: configuration[key]

  # The console is always configured: without settings it has bootstrap's
  # listener and no Work profile at all.
  defp console(state, nil, configuration) do
    %{
      csrf_secret: state.csrf_secret,
      ip: state.bootstrap.control_plane.ip,
      port: state.bootstrap.control_plane.port,
      slack: configuration[:slack],
      work_profile: nil
    }
  end

  defp console(state, control_plane, configuration) do
    control_plane
    |> Map.put(:csrf_secret, state.csrf_secret)
    |> Map.put(:slack, configuration[:slack])
  end

  defp reconcile_children(state, desired) do
    running =
      Enum.reduce(@children, state.running, fn {key, module}, running ->
        reconcile_child(state, running, key, module, Map.get(desired, key))
      end)

    %{state | running: running}
  end

  defp reconcile_child(_state, running, key, _module, nil) when not is_map_key(running, key),
    do: running

  defp reconcile_child(state, running, key, module, nil) do
    stop_child(state, running, key, module)
    Map.delete(running, key)
  end

  defp reconcile_child(state, running, key, module, configuration) do
    case Map.get(running, key) do
      %{configuration: ^configuration} ->
        running

      nil ->
        start_child(state, running, key, module, configuration)

      _changed ->
        stop_child(state, running, key, module)
        start_child(state, Map.delete(running, key), key, module, configuration)
    end
  end

  defp start_child(state, running, key, module, configuration) do
    specs = child_specs(key, module, configuration)

    started =
      Enum.reduce_while(specs, [], fn spec, started ->
        case DynamicSupervisor.start_child(state.supervisor, spec) do
          {:ok, pid} -> {:cont, [pid | started]}
          {:ok, pid, _info} -> {:cont, [pid | started]}
          # A companion that declines to run (an unconfigured name cache, say)
          # is not a failed apply; it has nothing to supervise.
          :ignore -> {:cont, started}
          {:error, reason} -> {:halt, {:error, reason, started}}
        end
      end)

    case started do
      {:error, reason, started} ->
        Enum.each(started, &DynamicSupervisor.terminate_child(state.supervisor, &1))
        Logger.warning("runtime #{key} did not start: #{inspect(reason)}")
        running

      pids ->
        Map.put(running, key, %{configuration: configuration, pids: Enum.reverse(pids)})
    end
  end

  defp stop_child(state, running, key, _module) do
    case Map.get(running, key) do
      %{pids: pids} ->
        pids
        |> Enum.reverse()
        |> Enum.each(&DynamicSupervisor.terminate_child(state.supervisor, &1))

      nil ->
        :ok
    end
  end

  # The name cache is handed the Slack runtime rather than reading it back out of
  # the application environment in `init`. A child that reads global state at
  # start is a child whose start depends on who ran before it: this one declined
  # with `:ignore` for weeks in production, and nothing retries an `:ignore`.
  defp child_specs(:control_plane, module, configuration) do
    {slack, console} = Map.pop(configuration, :slack)

    companions =
      Enum.map(@control_plane_companions, fn
        Responder.ControlPlane.SlackNames ->
          {Responder.ControlPlane.SlackNames, name_cache(slack)}

        companion ->
          {companion, []}
      end)

    companions ++ [{module, console}]
  end

  defp child_specs(_key, module, configuration), do: [{module, configuration}]

  defp name_cache(%{identity: %{workspace_ref: workspace}, bot_client: client})
       when is_binary(workspace),
       do: [
         workspace: workspace,
         fetch: &Client.directory_name(client, workspace, &1)
       ]

  defp name_cache(_slack), do: []

  defp record(revision, result) do
    case Settings.record_application(revision, result) do
      :ok -> :ok
      {:error, reason} -> Logger.info("settings application not recorded: #{inspect(reason)}")
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("settings application not recorded: #{inspect(error.__struct__)}")
  end

  defp read_settings do
    case Settings.fetch() do
      {:ok, settings} -> {:ok, settings}
      {:error, :settings_not_initialized} -> {:ok, :not_initialized}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, {:settings_unavailable, error.__struct__}}
  end

  defp retry(state, reason) do
    Logger.warning("durable settings are unavailable: #{inspect(reason)}")
    Process.send_after(self(), :retry, @retry_ms)
    {{:error, :settings_unavailable}, state}
  end

  defp bootstrap do
    case Application.get_env(:responder, :bootstrap) do
      %Bootstrap{} = bootstrap -> bootstrap
      _unset -> Bootstrap.load!()
    end
  end
end
