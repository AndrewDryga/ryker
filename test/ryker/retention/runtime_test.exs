defmodule Ryker.Retention.RuntimeTest do
  use ExUnit.Case, async: true
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Retention.{Runtime, Worker}

  test "runtime supervises one bounded cleanup worker with exact options" do
    configuration = configuration()
    options = Runtime.options!(configuration)
    assert Runtime.options!(Map.to_list(configuration)) == options

    assert options.worker_ref == "host-a:retention"
    assert options.closed_session_grace_seconds == 900
    assert options.operational_data_seconds == 86_400
    assert options.disposable_bytes_limit == 10_737_418_240

    dispatcher_options = child_dispatcher_options(configuration)
    assert Keyword.fetch!(dispatcher_options, :batch_limit) == 25
    assert Keyword.fetch!(dispatcher_options, :batch_seconds) == 30
    assert Keyword.fetch!(dispatcher_options, :retained_recheck_seconds) == 21_600

    assert {:ok, {flags, [child]}} = Runtime.init(configuration)
    assert flags.strategy == :one_for_one
    assert child.id == Worker

    # Data pruning is the worker's own; the runtime hands it the horizons only.
    worker_options = child.start |> elem(2) |> hd()
    refute Keyword.has_key?(worker_options, :maintenance)

    assert Keyword.fetch!(worker_options, :maintenance_options) == %{
             audit_data_seconds: 2_592_000,
             closed_work_seconds: 604_800,
             conversation_memory_seconds: 7_776_000,
             episode_history_seconds: 2_592_000,
             operational_data_seconds: 86_400,
             routing_examples_enabled: true,
             routing_examples_seconds: 31_536_000,
             work_examples_enabled: false,
             work_examples_seconds: 31_536_000
           }

    assert Runtime.child_spec(configuration()).id == Runtime
  end

  defp child_dispatcher_options(configuration) do
    {:ok, {_flags, [child]}} = Runtime.init(configuration)
    child.start |> elem(2) |> hd() |> Keyword.fetch!(:dispatcher_options)
  end

  test "runtime rejects missing, unknown, unordered, and unsafe configuration" do
    for invalid <- [
          Map.delete(configuration(), :client),
          Map.put(configuration(), :unknown, true),
          Map.put(configuration(), :lease_seconds, 0),
          Map.put(configuration(), :retry_max_seconds, 0),
          Map.put(configuration(), :operational_data_seconds, 700_000),
          Map.put(configuration(), :routing_examples_enabled, nil),
          Map.put(configuration(), :routing_examples_seconds, 0),
          Map.put(configuration(), :work_examples_enabled, nil),
          Map.put(configuration(), :work_examples_seconds, 0),
          Map.put(configuration(), :storage_reserve_bytes, 0),
          Map.put(configuration(), :batch_limit, 0),
          Map.put(configuration(), :batch_seconds, 120),
          Map.put(configuration(), :retained_recheck_seconds, 0),
          Map.put(configuration(), :worker_ref, <<0>>),
          [client: :one, client: :two],
          [:not_a_keyword],
          :not_a_configuration
        ] do
      assert_raise ArgumentError, fn -> Runtime.options!(invalid) end
    end
  end

  test "cleanup starts only on an explicit Coop adapter" do
    # A missing adapter used to fall back to the local Unix-socket client, which
    # is eval-only and left the release: cleanup must stop before supervision
    # rather than at its first Coop call.
    for invalid <- [
          Map.delete(configuration(), :api),
          Map.put(configuration(), :api, nil),
          Map.put(configuration(), :learning_api, nil)
        ] do
      assert_raise ArgumentError, fn -> Runtime.options!(invalid) end
    end

    options = Runtime.options!(configuration())
    assert options.api == Ryker.CoopFleet.Client
    assert options.learning_api == Ryker.CoopFleet.Client
    assert options.learning_client == :client
  end

  test "worker survives every dispatcher outcome and keeps polling" do
    for response <- [
          {:ok, pass(0, %{idle: true})},
          {:ok, pass(3, %{executed: 3})},
          {:ok, pass(2, %{deferred: 2, stopped: :time_budget})},
          {:ok, pass(1, %{blocked: 1})},
          {:error, :database_down}
        ] do
      assert {:ok, pid} =
               Worker.start_link(
                 dispatcher: __MODULE__.Dispatcher,
                 dispatcher_options: [response: response, test_pid: self()],
                 maintenance: __MODULE__.Maintenance,
                 maintenance_options: %{response: {:ok, :pruned}, test_pid: self()},
                 poll_interval_ms: 60_000
               )

      # The dispatcher message precedes the persisted progress beat and maintenance.
      # Wait for the poll callback, not a 100 ms scheduler race under full coverage.
      assert %{poll_interval_ms: 60_000} = :sys.get_state(pid)
      assert_receive {:retention_dispatch, ^response}
      assert_receive {:retention_maintenance, {:ok, :pruned}}
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  test "maintenance failures never stop cleanup polling" do
    for mode <- [:error, :raise, :throw] do
      assert {:ok, pid} =
               Worker.start_link(
                 dispatcher: __MODULE__.Dispatcher,
                 dispatcher_options: [
                   response: {:ok, pass(0, %{idle: true})},
                   test_pid: self()
                 ],
                 maintenance: __MODULE__.MaintenanceFailure,
                 maintenance_options: %{mode: mode, test_pid: self()},
                 poll_interval_ms: 60_000
               )

      assert %{poll_interval_ms: 60_000} = :sys.get_state(pid)
      assert_receive {:retention_dispatch, {:ok, %{idle: true}}}
      assert_receive {:retention_maintenance_failure, ^mode}
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    # Pruning is not optional: a worker without its horizons does not start.
    assert Worker.init(
             dispatcher: __MODULE__.Dispatcher,
             dispatcher_options: [],
             poll_interval_ms: 60_000
           ) == {:stop, {:invalid_retention_worker, :options}}
  end

  # One failing pruning phase makes the whole pass an error, and the worker
  # then skipped clearing orphaned command bodies on every pass while the phase
  # kept failing, though those files never depend on it (2026-10-04 review).
  test "orphaned command bodies are cleared even when a pruning phase failed" do
    owner = Sandbox.start_owner!(Ryker.Repo)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    root = Path.join(System.tmp_dir!(), "ryker-bodies-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    orphan = Path.join(root, Ecto.UUID.generate())
    File.mkdir_p!(orphan)
    File.touch!(orphan, System.os_time(:second) - 86_401)
    failed = {:error, {:retention_phases_failed, [:expiring]}}

    assert {:ok, pid} =
             Worker.start_link(
               dispatcher: __MODULE__.HeldDispatcher,
               dispatcher_options: [],
               maintenance: __MODULE__.Maintenance,
               maintenance_options: %{response: failed, test_pid: self()},
               body_root: root,
               poll_interval_ms: 60_000
             )

    # The first poll waits for this, so it reads the database as this test.
    Sandbox.allow(Ryker.Repo, owner, pid)
    send(pid, :dispatch)
    assert_receive {:retention_maintenance, ^failed}
    assert %{poll_interval_ms: 60_000} = :sys.get_state(pid)
    refute File.exists?(orphan)
    GenServer.stop(pid)
  end

  defp pass(attempted, overrides) do
    Map.merge(
      %{
        attempted: attempted,
        blocked: 0,
        deferred: 0,
        executed: 0,
        idle: false,
        stopped: :batch_limit
      },
      overrides
    )
  end

  defp configuration do
    %{
      api: Ryker.CoopFleet.Client,
      audit_data_seconds: 2_592_000,
      batch_limit: 25,
      batch_seconds: 30,
      client: :client,
      closed_session_grace_seconds: 900,
      closed_work_seconds: 604_800,
      conversation_memory_seconds: 7_776_000,
      disposable_bytes_limit: 10_737_418_240,
      episode_history_seconds: 2_592_000,
      lease_seconds: 300,
      max_attempts: 8,
      operational_data_seconds: 86_400,
      poll_interval_ms: 60_000,
      reclaim_target_seconds: 3_600,
      retained_recheck_seconds: 21_600,
      retry_base_seconds: 5,
      retry_max_seconds: 300,
      routing_examples_enabled: true,
      routing_examples_seconds: 31_536_000,
      work_examples_enabled: false,
      work_examples_seconds: 31_536_000,
      storage_reserve_bytes: 5_368_709_120,
      worker_ref: "host-a:retention"
    }
  end

  defmodule Dispatcher do
    @moduledoc false
    def run_pass(options) do
      response = Keyword.fetch!(options, :response)
      send(Keyword.fetch!(options, :test_pid), {:retention_dispatch, response})
      response
    end
  end

  defmodule HeldDispatcher do
    @moduledoc false
    def run_pass(_options) do
      receive do
        :dispatch -> {:ok, %{attempted: 0}}
      end
    end
  end

  defmodule Maintenance do
    @moduledoc false
    def prune(options) do
      response = Map.fetch!(options, :response)
      send(Map.fetch!(options, :test_pid), {:retention_maintenance, response})
      response
    end
  end

  defmodule MaintenanceFailure do
    @moduledoc false

    def prune(%{mode: mode, test_pid: test_pid}) do
      send(test_pid, {:retention_maintenance_failure, mode})
      fail(mode)
    end

    defp fail(:error), do: {:error, :maintenance_failed}
    defp fail(:raise), do: raise("maintenance crashed")
    defp fail(:throw), do: throw(:maintenance_threw)
  end
end
