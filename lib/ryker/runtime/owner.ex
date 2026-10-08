defmodule Ryker.Runtime.Owner do
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

  Each key runs under a supervisor of its own (`Ryker.Runtime.Child`), which
  the owner monitors and stops to stop the key. A child restarted after a crash
  is therefore still replaced by the next change, and a key that crashes past
  its own restart limit is started again by the owner, after a pause that
  doubles while it keeps failing, without taking the other keys down. A start
  that failed, or a database that could not be read, is retried the same way.
  An owner that itself restarted stops whatever its predecessor left running
  and starts from the saved revision.
  """
  use GenServer
  alias Ryker.Backoff
  alias Ryker.{Bootstrap, Credentials, Settings}
  alias Ryker.Config
  alias Ryker.Crypto
  alias Ryker.Runtime.{Assembly, Child}
  alias Ryker.Slack
  require Logger

  @retry_ms 5_000
  @retry_max_ms 300_000
  # A key that went down this recently is still failing, so a start that works
  # does not reset the pause before the next try.
  @settled_ms 300_000

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
    Settings.subscribe()
    Credentials.subscribe()
    supervisor = Keyword.get(options, :supervisor, Ryker.Runtime.Supervisor)
    stop_leftovers(supervisor)

    state = %{
      bootstrap: Keyword.get_lazy(options, :bootstrap, &bootstrap/0),
      csrf_secret: Crypto.random_bytes(32),
      revision: nil,
      supervisor: supervisor,
      running: %{},
      retry_ms: Keyword.get(options, :retry_ms, @retry_ms),
      retries: 0,
      retry_timer: nil,
      down_at: nil
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
    keys = for {key, %{pid: pid}} <- state.running, running?(pid), do: key

    {:reply, keys, state}
  end

  # A save the owner hears about and a retry it scheduled itself are the same
  # request: apply whatever is saved now.
  @impl true
  def handle_info(:retry, state) do
    {_result, state} = apply_latest(%{state | retry_timer: nil})
    {:noreply, state}
  end

  def handle_info(message, state)
      when is_tuple(message) and elem(message, 0) == :settings_saved do
    {_result, state} = apply_latest(state)
    {:noreply, state}
  end

  # A key's supervisor ends only when the owner stops it, which demonitors it
  # first, or when its children crashed past their restart limit. The key is
  # started again on a retry.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.running, fn {_key, child} -> child.ref == ref end) do
      {key, _child} ->
        Logger.warning(
          "runtime #{key} stopped and will be started again: #{inspect(reason, limit: 5)}"
        )

        state = %{
          state
          | running: Map.delete(state.running, key),
            revision: nil,
            down_at: System.monotonic_time(:millisecond)
        }

        {:noreply, schedule_retry(state)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:credentials_changed, _kind, _name}, state) do
    # Credentials are deliberately outside ordinary settings history. Force
    # one assembly pass at the same settings revision so only child configs
    # whose resolved secret changed are replaced.
    {_result, state} = apply_latest(%{state | revision: nil})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_latest(state) do
    {result, state} =
      case read_settings() do
        {:ok, :not_initialized} -> apply_fresh_setup(state)
        {:ok, settings} -> apply_settings(state, settings)
        {:error, reason} -> unavailable(state, reason)
      end

    {result, after_apply(result, state)}
  end

  # A start that failed or a database that could not be read is tried again,
  # each pause twice the last; a revision that cannot be assembled waits for the
  # next save, since assembling it again gives the same answer.
  defp after_apply({:ok, _result}, state), do: settled(state)
  defp after_apply({:error, :settings_unavailable}, state), do: schedule_retry(state)

  defp after_apply({:error, {:runtime_start_failed, _key, _reason}}, state),
    do: schedule_retry(state)

  defp after_apply({:error, _assembly}, state), do: state

  defp settled(%{down_at: down_at} = state) when is_integer(down_at) do
    if System.monotonic_time(:millisecond) - down_at < @settled_ms,
      do: state,
      else: %{state | retries: 0, down_at: nil}
  end

  defp settled(state), do: %{state | retries: 0}

  defp schedule_retry(%{retry_timer: nil} = state) do
    delay = Backoff.delay(state.retries + 1, state.retry_ms, @retry_max_ms, 16)
    %{state | retry_timer: Process.send_after(self(), :retry, delay), retries: state.retries + 1}
  end

  defp schedule_retry(state), do: state

  # Setup must be reachable before any product configuration exists, so the
  # console runs from bootstrap alone and nothing else starts.
  defp apply_fresh_setup(state) do
    case reconcile_children(state, %{control_plane: console(state, nil)}) do
      {state, []} -> {{:ok, :not_initialized}, %{state | revision: nil}}
      {state, [failure | _rest]} -> {{:error, failure}, %{state | revision: nil}}
    end
  end

  defp apply_settings(%{revision: revision} = state, %{installation: %{revision: revision}}),
    do: {{:ok, :unchanged}, state}

  defp apply_settings(state, settings) do
    revision = settings.installation.revision

    case build(state.bootstrap, settings) do
      {:ok, configuration} ->
        # Publish before starting anything. A child that reads another
        # runtime's published configuration in `init` — the Slack name cache
        # does — otherwise starts against the previous value and declines with
        # `:ignore`, which is permanent: nothing restarts a runtime whose own
        # configuration never changed again.
        Assembly.publish(configuration)
        start_children(state, revision, applied_children(state, configuration))

      {:error, {:settings_unavailable, _detail} = reason} ->
        unavailable(state, reason)

      {:error, reason} ->
        # The saved revision stays saved and visibly unapplied; the running
        # children keep the last configuration that actually assembled.
        Logger.warning("settings revision #{revision} could not be applied: #{inspect(reason)}")
        record(revision, {:error, :assembly_failed})
        {{:error, reason}, state}
    end
  end

  # Assembling reads credentials and settings rows; a database that cannot
  # answer is the same outage `read_settings/0` sees, not a revision that is
  # wrong.
  defp build(bootstrap, settings) do
    Assembly.build(bootstrap, settings)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, {:settings_unavailable, error.__struct__}}
  end

  defp start_children(state, revision, desired) do
    case reconcile_children(state, desired) do
      {state, []} ->
        record(revision, :ok)
        {{:ok, :applied}, %{state | revision: revision}}

      {state, [failure | _rest]} ->
        # The children that did start keep the new configuration; the revision
        # stays unapplied so the next reconcile, a save or an operator asking,
        # starts the missing ones again instead of answering :unchanged for a
        # runtime that is not running.
        record(revision, {:error, :runtime_start_failed})
        {{:error, failure}, state}
    end
  end

  defp applied_children(state, configuration) do
    Map.new(Assembly.runtimes(), fn {key, _module} ->
      {key, child_configuration(state, key, configuration)}
    end)
    |> Enum.reject(fn {_key, configuration} -> is_nil(configuration) end)
    |> Map.new()
  end

  defp child_configuration(state, :control_plane, configuration) do
    console(state, configuration[:control_plane])
  end

  defp child_configuration(_state, key, configuration), do: configuration[key]

  # The console is always configured: without settings it has bootstrap's
  # listener, no environment Chat could run in and no Work profile at all.
  defp console(state, nil) do
    %{
      access: Map.get(state.bootstrap.control_plane, :access, :loopback),
      csrf_secret: state.csrf_secret,
      ip: state.bootstrap.control_plane.ip,
      port: state.bootstrap.control_plane.port,
      public_url: state.bootstrap.control_public_url,
      cloudflare_access: state.bootstrap.cloudflare_access
    }
  end

  defp console(state, control_plane),
    do: Map.put(control_plane, :csrf_secret, state.csrf_secret)

  # Starts, replaces and stops children in dependency order and reports every
  # child that would not start as `{:runtime_start_failed, key, reason}`.
  defp reconcile_children(state, desired) do
    {running, failures} =
      Enum.reduce(Assembly.runtimes(), {state.running, []}, fn {key, module},
                                                               {running, failures} ->
        case reconcile_child(state, running, key, module, Map.get(desired, key)) do
          {:ok, running} ->
            {running, failures}

          {:error, running, reason} ->
            {running, [{:runtime_start_failed, key, reason} | failures]}
        end
      end)

    {%{state | running: running}, Enum.reverse(failures)}
  end

  defp reconcile_child(_state, running, key, _module, nil) when not is_map_key(running, key),
    do: {:ok, running}

  defp reconcile_child(state, running, key, _module, nil) do
    stop_child(state, running, key)
    {:ok, Map.delete(running, key)}
  end

  defp reconcile_child(state, running, key, module, configuration) do
    case Map.get(running, key) do
      %{configuration: ^configuration} ->
        {:ok, running}

      nil ->
        start_child(state, running, key, module, configuration)

      %{configuration: previous} = child ->
        if reconfigured?(module, previous, configuration) do
          {:ok, Map.put(running, key, %{child | configuration: configuration})}
        else
          stop_child(state, running, key)
          start_child(state, Map.delete(running, key), key, module, configuration)
        end
    end
  end

  # A runtime that can take a new configuration while it runs says so, as the console does for
  # everything but its listener; a restart drops what it holds open, such as every open page.
  defp reconfigured?(module, previous, configuration) do
    Code.ensure_loaded?(module) and function_exported?(module, :reconfigure, 2) and
      module.reconfigure(previous, configuration) == :ok
  end

  # The key's processes start in order under their own supervisor. A companion
  # that declines to run (an unconfigured name cache, say) is not a failed
  # apply; it has nothing to supervise, and the key does not count as running.
  defp start_child(state, running, key, module, configuration) do
    spec = Child.child_spec({key, child_specs(key, module, configuration)})

    case DynamicSupervisor.start_child(state.supervisor, spec) do
      {:ok, pid} ->
        child = %{configuration: configuration, pid: pid, ref: Process.monitor(pid)}
        {:ok, Map.put(running, key, child)}

      {:error, reason} ->
        reason = start_failure(reason)
        Logger.warning("runtime #{key} did not start: #{inspect(reason)}")
        {:error, running, reason}
    end
  end

  defp start_failure({:shutdown, {:failed_to_start_child, _id, reason}}), do: reason
  defp start_failure(reason), do: reason

  defp stop_child(state, running, key) do
    case Map.get(running, key) do
      %{pid: pid, ref: ref} ->
        Process.demonitor(ref, [:flush])
        DynamicSupervisor.terminate_child(state.supervisor, pid)

      nil ->
        :ok
    end
  end

  # The owner is the only one that starts children here, so whatever runs when
  # it starts was left by an owner that crashed and is no longer known to anyone.
  defp stop_leftovers(supervisor) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid),
        do: DynamicSupervisor.terminate_child(supervisor, pid)

    :ok
  end

  defp running?(pid) do
    Process.alive?(pid) and
      Enum.any?(Supervisor.which_children(pid), fn {_id, child, _type, _modules} ->
        is_pid(child)
      end)
  catch
    :exit, _reason -> false
  end

  # The console's companion starts before it: the clock that tells open pages
  # a Coop worker stopped reporting, which no commit says.
  defp child_specs(:control_plane, module, configuration),
    do: [{Ryker.ControlPlane.WorkerLiveness, []}, {module, configuration}]

  # The name cache is handed its workspace and lookup rather than reading them
  # back out of the application environment in `init`. A child that reads
  # global state at start is a child whose start depends on who ran before it:
  # it declined with `:ignore` for weeks in production, and nothing retries an
  # `:ignore`. It is its own child, not the console's, so no Slack setting but
  # the workspace and its token restarts it and empties it.
  defp child_specs(:slack_names, Slack.Names, %{workspace: workspace, client: client} = names),
    do: [
      {Slack.Names,
       workspace: workspace,
       workspace_url: names.workspace_url,
       known: Map.get(names, :known, []),
       fetch: &Slack.Client.Users.directory_name(client, workspace, &1)}
    ]

  defp child_specs(_key, module, configuration), do: [{module, configuration}]

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

  defp unavailable(state, reason) do
    Logger.warning("durable settings are unavailable: #{inspect(reason)}")
    {{:error, :settings_unavailable}, state}
  end

  defp bootstrap do
    case Config.get_env(:bootstrap) do
      %Bootstrap{} = bootstrap -> bootstrap
      _unset -> Bootstrap.load!()
    end
  end
end
