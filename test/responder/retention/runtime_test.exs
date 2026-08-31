defmodule Responder.Retention.RuntimeTest do
  use ExUnit.Case, async: true

  alias Responder.Retention.{Runtime, Worker}

  test "runtime supervises one bounded cleanup worker with exact options" do
    configuration = configuration()
    options = Runtime.options!(configuration)
    assert Runtime.options!(Map.to_list(configuration)) == options

    assert options.worker_ref == "host-a:retention"
    assert options.closed_session_grace_seconds == 900
    assert options.operational_data_seconds == 86_400

    assert {:ok, {flags, [child]}} = Runtime.init(configuration)
    assert flags.strategy == :one_for_one
    assert child.id == Worker

    assert child.start |> elem(2) |> hd() |> Keyword.fetch!(:maintenance) ==
             Responder.Retention.Data

    assert Runtime.child_spec(configuration()).id == Runtime
  end

  test "runtime rejects missing, unknown, unordered, and unsafe configuration" do
    for invalid <- [
          Map.delete(configuration(), :client),
          Map.put(configuration(), :unknown, true),
          Map.put(configuration(), :lease_seconds, 0),
          Map.put(configuration(), :retry_max_seconds, 0),
          Map.put(configuration(), :operational_data_seconds, 700_000),
          Map.put(configuration(), :worker_ref, <<0>>),
          [client: :one, client: :two],
          [:not_a_keyword],
          :not_a_configuration
        ] do
      assert_raise ArgumentError, fn -> Runtime.options!(invalid) end
    end
  end

  test "worker survives every dispatcher outcome and keeps polling" do
    for response <- [
          {:ok, :idle},
          {:ok, {:executed, %{phase: :closed}}},
          {:ok, {:deferred, :temporary}},
          {:ok, {:blocked, :unsafe}},
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

      assert_receive {:retention_dispatch, ^response}
      assert_receive {:retention_maintenance, {:ok, :pruned}}
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  test "maintenance absence and failures never stop cleanup polling" do
    assert {:ok, nil_maintenance} =
             Worker.start_link(
               dispatcher: __MODULE__.Dispatcher,
               dispatcher_options: [response: {:ok, :idle}, test_pid: self()],
               poll_interval_ms: 60_000
             )

    assert_receive {:retention_dispatch, {:ok, :idle}}
    assert Process.alive?(nil_maintenance)
    GenServer.stop(nil_maintenance)

    for mode <- [:error, :raise, :throw] do
      assert {:ok, pid} =
               Worker.start_link(
                 dispatcher: __MODULE__.Dispatcher,
                 dispatcher_options: [response: {:ok, :idle}, test_pid: self()],
                 maintenance: __MODULE__.MaintenanceFailure,
                 maintenance_options: %{mode: mode, test_pid: self()},
                 poll_interval_ms: 60_000
               )

      assert_receive {:retention_dispatch, {:ok, :idle}}
      assert_receive {:retention_maintenance_failure, ^mode}
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    assert {:stop, {:invalid_retention_worker, :options}} =
             Worker.init(
               dispatcher: __MODULE__.Dispatcher,
               dispatcher_options: [],
               maintenance: __MODULE__.Maintenance,
               maintenance_options: nil,
               poll_interval_ms: 60_000
             )
  end

  defp configuration do
    %{
      audit_data_seconds: 2_592_000,
      client: :client,
      closed_session_grace_seconds: 900,
      closed_work_seconds: 604_800,
      conversation_memory_seconds: 7_776_000,
      episode_history_seconds: 2_592_000,
      lease_seconds: 300,
      max_attempts: 8,
      operational_data_seconds: 86_400,
      poll_interval_ms: 60_000,
      retry_base_seconds: 5,
      retry_max_seconds: 300,
      worker_ref: "host-a:retention"
    }
  end

  defmodule Dispatcher do
    @moduledoc false
    def run_once(options) do
      response = Keyword.fetch!(options, :response)
      send(Keyword.fetch!(options, :test_pid), {:retention_dispatch, response})
      response
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
