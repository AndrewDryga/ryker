defmodule Ryker.PollingTest do
  use Ryker.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ryker.Observability
  alias Ryker.Polling
  alias Ryker.Retention.Worker

  defmodule DatabaseDispatcher do
    def run_pass(options) do
      parent = Keyword.fetch!(options, :parent)
      pool = Keyword.fetch!(options, :pool)
      send(parent, {:poll_attempt, self(), System.monotonic_time(:millisecond)})
      previous = Ryker.Repo.put_dynamic_repo(pool)

      try do
        Ryker.Repo.query!("SELECT 1", [], log: false, timeout: 50)
      rescue
        error in DBConnection.ConnectionError ->
          send(parent, {:pool_exhausted, self()})
          reraise error, __STACKTRACE__
      after
        Ryker.Repo.put_dynamic_repo(previous)
      end

      send(parent, {:query_completed, self()})
      {:ok, %{attempted: 0, blocked: 0, deferred: 0, executed: 0, idle: true, stopped: :idle}}
    end
  end

  defmodule Maintenance do
    def prune(%{parent: parent}) do
      send(parent, {:maintenance_ran, self()})
      {:ok, %{}}
    end
  end

  defmodule FailingDispatcher do
    def run_pass(kind: :argument), do: raise(ArgumentError, "invalid polling operation")
    def run_pass(kind: :throw), do: throw(:invalid_polling_operation)
    def run_pass(kind: :exit), do: exit(:invalid_polling_operation)
  end

  # Pool starvation killed 17 poller processes in 328 ms, spending the supervisor
  # restart budget and taking Ryker down. A failed cycle must wait, not crash
  # or report successful progress, then recover without a supervisor restart.
  test "a polling process survives pool exhaustion and resumes on its own delayed timer" do
    pool = isolated_pool!()
    holder = hold_connection!(pool)
    parent = self()

    worker =
      start_supervised!(
        Supervisor.child_spec(
          {Worker,
           dispatcher: DatabaseDispatcher,
           dispatcher_options: [parent: parent, pool: pool],
           maintenance: Maintenance,
           maintenance_options: %{parent: parent},
           poll_interval_ms: 10},
          restart: :temporary
        )
      )

    monitor = Process.monitor(worker)
    assert_receive {:poll_attempt, ^worker, first_attempt}, 1_000
    assert_receive {:pool_exhausted, ^worker}, 1_000

    refute_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 100
    assert Process.alive?(worker)
    refute_receive {:poll_attempt, ^worker, _time}, 100
    refute_receive {:maintenance_ran, ^worker}

    assert Repo.query!("SELECT cycle_count FROM ryker_runtime_progress WHERE lane = 'retention'").rows ==
             []

    assert {:error, {:database_unavailable, _reason}} =
             with_pool(pool, &Observability.health/0)

    assert {:error, _reason} =
             with_pool(pool, fn ->
               Observability.ready(check_runtimes: false, check_progress: false)
             end)

    send(holder, :release_connection)
    assert_receive {:connection_released, ^holder}, 1_000
    assert_receive {:poll_attempt, ^worker, retry_attempt}, 2_000
    assert retry_attempt - first_attempt >= 1_000
    assert_receive {:query_completed, ^worker}, 1_000
    assert_receive {:maintenance_ran, ^worker}, 1_000
    assert Process.alive?(worker)

    assert [[count]] =
             Repo.query!(
               "SELECT cycle_count FROM ryker_runtime_progress WHERE lane = 'retention'"
             ).rows

    assert count >= 1
    assert {:ok, %{database: :ok}} = with_pool(pool, &Observability.health/0)

    assert {:ok, _readiness} =
             with_pool(pool, fn ->
               Observability.ready(check_runtimes: false, check_progress: false)
             end)
  end

  test "polling does not swallow programming errors" do
    assert_raise ArgumentError, "invalid polling operation", fn ->
      Worker.handle_info(:poll, failing_state(:argument))
    end

    refute_receive :poll
  end

  test "polling does not swallow throws" do
    assert catch_throw(Worker.handle_info(:poll, failing_state(:throw))) ==
             :invalid_polling_operation

    refute_receive :poll
  end

  test "polling does not swallow exits" do
    assert catch_exit(Worker.handle_info(:poll, failing_state(:exit))) ==
             :invalid_polling_operation

    refute_receive :poll
  end

  test "healthy polling preserves both immediate work and configured idle delays" do
    assert Polling.run(:retention, 60_000, fn -> 0 end) == 0
    assert Polling.run(:retention, 60_000, fn -> 60_000 end) == 60_000
  end

  test "database backoff never shortens the configured interval or retries inside the guard" do
    parent = self()

    delay =
      Polling.run(:retention, 60_000, fn ->
        send(parent, :cycle_attempted)
        raise DBConnection.ConnectionError, "private SQL and connection details"
      end)

    assert delay == 60_000
    assert_receive :cycle_attempted
    refute_receive :cycle_attempted
  end

  test "database polling warnings do not expose exception payloads" do
    log =
      capture_log(fn ->
        assert Polling.run(:retention, 10, fn ->
                 raise DBConnection.ConnectionError, "private SQL and connection details"
               end) == 1_000
      end)

    assert log =~ "database polling unavailable; retrying after backoff"
    assert log =~ "(retention, 1000 ms)"
    refute log =~ "private SQL"
    refute log =~ "connection details"
  end

  defp failing_state(kind) do
    %{
      dispatcher: FailingDispatcher,
      dispatcher_options: [kind: kind],
      maintenance: nil,
      maintenance_options: nil,
      poll_interval_ms: 10
    }
  end

  defp isolated_pool! do
    options = [
      name: nil,
      pool: DBConnection.ConnectionPool,
      pool_size: 1,
      timeout: 50,
      queue_target: 10,
      queue_interval: 10
    ]

    start_supervised!(Supervisor.child_spec({Repo, options}, id: :isolated_polling_pool))
  end

  defp hold_connection!(pool) do
    parent = self()

    holder =
      spawn(fn ->
        with_pool(pool, fn -> checkout_until_released(parent) end)

        send(parent, {:connection_released, self()})
      end)

    on_exit(fn -> send(holder, :release_connection) end)
    assert_receive {:connection_held, ^holder}, 1_000
    holder
  end

  defp checkout_until_released(parent) do
    Repo.checkout(
      fn ->
        send(parent, {:connection_held, self()})

        receive do
          :release_connection -> :ok
        after
          10_000 -> raise "test did not release its isolated database connection"
        end
      end,
      timeout: 15_000
    )
  end

  defp with_pool(pool, operation) do
    previous = Repo.put_dynamic_repo(pool)

    try do
      operation.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
