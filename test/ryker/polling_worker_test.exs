defmodule Ryker.PollingWorkerTest do
  use Ryker.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ryker.Observability
  alias Ryker.PollingWorker
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

  defmodule OnboardingAPI do
    def pin(_binding, _repository), do: {:error, :not_used}
    def scan(_binding, _repository, _commit), do: {:error, :not_used}
    def publish(_binding, _repository, _commit, _content), do: {:error, :not_used}
  end

  defmodule WokenWorker do
    use Ryker.PollingWorker, lane: :woken_test, interval: :interval_ms

    def start_link(options), do: GenServer.start_link(__MODULE__, Map.new(options))

    @impl Ryker.PollingWorker
    def wake_on(state), do: [fn -> Ryker.PubSub.subscribe(state.topic) end]

    @impl Ryker.PollingWorker
    def poll(state) do
      send(state.parent, {:polled, self(), System.monotonic_time(:millisecond)})
      state.interval_ms
    end
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

  # On 2026-09-27 an idle install committed about 125 transactions a second:
  # every worker polled its table on a 250 ms or 1 s timer whether or not
  # anything had changed. A worker now sleeps until something it reads is
  # announced, so an announcement has to reach it at once, and the many that
  # one change can make (every row of a batch, every step of a claim) must
  # cost one poll, not one each.
  test "an announcement a worker names wakes it at once, and a burst makes one poll" do
    topic = "polling-worker-test:#{System.unique_integer([:positive])}"

    worker =
      start_supervised!({WokenWorker, parent: self(), topic: topic, interval_ms: 60_000})

    assert_receive {:polled, ^worker, _at}, 1_000
    refute_receive {:polled, ^worker, _at}, 100

    :ok = :sys.suspend(worker)
    for change <- 1..5, do: Ryker.PubSub.broadcast(topic, {:changed, change})
    :ok = :sys.resume(worker)

    assert_receive {:polled, ^worker, _at}, 500
    refute_receive {:polled, ^worker, _at}, 200

    Ryker.PubSub.broadcast(topic, {:changed, 6})
    assert_receive {:polled, ^worker, _at}, 500
  end

  # A request's topics hear every activity step of every running turn, and
  # a dozen workers now listen to them. Answering each step with a poll would
  # have polled more under load than the old timers ever did.
  test "a stream of announcements never makes a worker poll more than four times a second" do
    topic = "polling-worker-test:#{System.unique_integer([:positive])}"

    worker =
      start_supervised!({WokenWorker, parent: self(), topic: topic, interval_ms: 60_000})

    assert_receive {:polled, ^worker, _at}, 1_000
    started = System.monotonic_time(:millisecond)

    for change <- 1..60 do
      Ryker.PubSub.broadcast(topic, {:changed, change})
      Process.sleep(10)
    end

    polls = received_polls(worker, [], 400)
    # The first four at once, then one each 250 ms: seven in about 750 ms.
    assert length(polls) in 5..8
    assert polls |> Enum.take(4) |> Enum.all?(&(&1 - started < 150))
  end

  # Every worker now handles every message, to hear the announcements it
  # names. One that names none, and is sent something anyway, says so and
  # keeps polling, as a plain GenServer would.
  test "a stray message to a worker that names no announcements is logged, not fatal" do
    log =
      capture_log(fn ->
        worker =
          start_supervised!(
            {Ryker.GitHub.OnboardingWorker, api: OnboardingAPI, interval_ms: 60_000}
          )

        send(worker, {:changed, 1})
        _state = :sys.get_state(worker)
        assert Process.alive?(worker)
      end)

    assert log =~ "unexpected message"
  end

  test "an idle worker sleeps until its next row falls due, never past its safety net" do
    now = DateTime.utc_now()
    parent = self()

    asked = fn due_at ->
      fn since ->
        send(parent, {:since, since})
        due_at
      end
    end

    assert PollingWorker.idle_delay(asked.(nil), 10_000) == 10_000
    assert_receive {:since, since}
    # It asks from a second ago, so a row that fell due during the cycle counts.
    assert DateTime.diff(now, since, :millisecond) in 900..1_100

    delay = PollingWorker.idle_delay(asked.(DateTime.add(now, 3, :second)), 10_000)
    assert delay in 2_900..3_000

    assert PollingWorker.idle_delay(asked.(DateTime.add(now, 60, :second)), 10_000) == 10_000

    # Due already: the claim missed it by a moment, or it waits behind another
    # row. Either way it is polled for again soon, never in a tight loop.
    assert PollingWorker.idle_delay(asked.(DateTime.add(now, -500, :millisecond)), 10_000) ==
             250
  end

  test "healthy polling preserves both immediate work and configured idle delays" do
    assert PollingWorker.run(:retention, 60_000, fn -> 0 end) == 0
    assert PollingWorker.run(:retention, 60_000, fn -> 60_000 end) == 60_000
  end

  test "database backoff never shortens the configured interval or retries inside the guard" do
    parent = self()

    delay =
      PollingWorker.run(:retention, 60_000, fn ->
        send(parent, :cycle_attempted)
        raise DBConnection.ConnectionError, "private SQL and connection details"
      end)

    assert delay == 60_000
    assert_receive :cycle_attempted
    refute_receive :cycle_attempted
  end

  # A statement the database refused (a connection limit, a cancelled
  # statement, a lock that timed out) raised out of the cycle and into the
  # supervisor exactly like the pool exhaustion above: only a lost connection
  # backed off, so every poller restarted at once and spent the same budget.
  test "a statement the database refused backs off like a lost connection" do
    parent = self()

    log =
      capture_log(fn ->
        delay =
          PollingWorker.run(:retention, 60_000, fn ->
            send(parent, :cycle_attempted)

            raise Postgrex.Error,
              postgres: %{
                code: "53300",
                message: "private connection details",
                severity: "FATAL"
              }
          end)

        assert delay == 60_000
      end)

    assert_receive :cycle_attempted
    refute_receive :cycle_attempted
    assert log =~ "database polling unavailable; retrying after backoff"
    assert log =~ "too_many_connections"
    refute log =~ "private connection details"
  end

  test "database polling warnings do not expose exception payloads" do
    log =
      capture_log(fn ->
        assert PollingWorker.run(:retention, 10, fn ->
                 raise DBConnection.ConnectionError, "private SQL and connection details"
               end) == 1_000
      end)

    assert log =~ "database polling unavailable; retrying after backoff"
    assert log =~ "(retention, 1000 ms)"
    refute log =~ "private SQL"
    refute log =~ "connection details"
  end

  defp received_polls(worker, polls, quiet_ms) do
    receive do
      {:polled, ^worker, at} -> received_polls(worker, [at | polls], quiet_ms)
    after
      quiet_ms -> Enum.reverse(polls)
    end
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
