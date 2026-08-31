defmodule Responder.State.ScheduleRuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Responder.State.{ScheduleDispatcher, ScheduleRuntime, ScheduleWorker}

  defmodule Custody do
    use Agent

    def start_link(state), do: Agent.start_link(fn -> state end, name: __MODULE__)

    def claim_due(worker_ref, lease_seconds) do
      Agent.get_and_update(__MODULE__, fn state ->
        [result | rest] = state.claims

        {result,
         %{state | calls: [{:claim, worker_ref, lease_seconds} | state.calls], claims: rest}}
      end)
    end

    def dispatch(schedule_ref, lease_ref, resolver, grace_seconds) do
      Agent.get_and_update(__MODULE__, fn state ->
        call = {:dispatch, schedule_ref, lease_ref, grace_seconds}
        resolved = resolver.(state.schedule)
        {state.dispatch, %{state | calls: [{call, resolved} | state.calls]}}
      end)
    end

    def defer(schedule_ref, lease_ref, delay, reason) do
      Agent.get_and_update(__MODULE__, fn state ->
        call = {:defer, schedule_ref, lease_ref, delay, reason}
        {state.defer, %{state | calls: [call | state.calls]}}
      end)
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  end

  @digest String.duplicate("a", 64)

  test "runtime pins each schedule authority to the trusted policy catalog" do
    options = ScheduleRuntime.options!(configuration())
    resolver = Keyword.fetch!(options.dispatcher_options, :policy_resolver)

    assert resolver.(%{authority: :read_only}) ==
             {:ok, %{name: "read-only", digest: @digest}}

    assert resolver.(%{authority: :governed_operation}) ==
             {:ok, %{name: "governed", digest: String.duplicate("b", 64)}}

    assert resolver.(%{authority: :repository_write, repository: "octo/example"}) ==
             {:ok, %{name: "repository-write", digest: String.duplicate("c", 64)}}

    assert resolver.(%{authority: :repository_write, repository: "missing"}) == :error
    assert resolver.(%{authority: :unknown}) == {:error, :schedule_policy_unavailable}

    assert options.poll_interval_ms == 25
    assert Keyword.fetch!(options.dispatcher_options, :worker_ref) == "schedule-worker:test"

    assert %{id: ScheduleRuntime, type: :worker, start: {ScheduleWorker, :start_link, [_]}} =
             ScheduleRuntime.child_spec(configuration())
  end

  test "dispatcher executes, defers with bounded backoff, and reports a failed defer" do
    claim = %{lease_ref: "lease:one", schedule: %{failure_count: 2, ref: "schedule:one"}}

    start_supervised!(
      {Custody,
       %{
         calls: [],
         claims: [{:ok, nil}, {:ok, claim}, {:ok, claim}, {:ok, claim}],
         defer: {:ok, %{ref: "schedule:one"}},
         dispatch: {:ok, %{status: :dispatched}},
         schedule: %{authority: :read_only}
       }}
    )

    options = dispatcher_options()
    assert ScheduleDispatcher.run_once(options) == {:ok, :idle}

    assert ScheduleDispatcher.run_once(options) ==
             {:ok, {:executed, %{status: :dispatched}}}

    Agent.update(Custody, &%{&1 | dispatch: {:error, :repository_busy}})

    assert ScheduleDispatcher.run_once(options) == {:ok, {:deferred, :repository_busy}}
    assert {:defer, "schedule:one", "lease:one", 20, :repository_busy} in Custody.calls()

    Agent.update(Custody, &%{&1 | defer: {:error, :lease_lost}})

    assert ScheduleDispatcher.run_once(options) ==
             {:error, {:schedule_dispatch_failed, :repository_busy, :lease_lost}}
  end

  test "worker polls without turning an idle or failed dispatch into a crash" do
    start_supervised!(
      {Custody,
       %{
         calls: [],
         claims: [{:ok, nil}, {:error, :database_unavailable}],
         defer: {:ok, %{}},
         dispatch: {:ok, %{}},
         schedule: %{authority: :read_only}
       }}
    )

    {:ok, worker} =
      start_supervised(
        {ScheduleWorker, dispatcher_options: dispatcher_options(), poll_interval_ms: 10}
      )

    Process.sleep(5)
    assert Process.alive?(worker)
    assert [{:claim, "schedule-worker:test", 30} | _] = Custody.calls()

    log =
      capture_log(fn ->
        send(worker, :poll)
        Process.sleep(5)
      end)

    assert log =~ "schedule dispatcher failed"
    assert Process.alive?(worker)
  end

  test "configuration and dispatcher reject ambiguous or unsafe authority settings" do
    invalid_configurations = [
      [],
      [worker_ref: "one", worker_ref: "two"],
      %{configuration() | repositories: []},
      %{configuration() | read_only_policy: %{name: "read-only", digest: "bad"}},
      %{configuration() | governed_operation_policy: %{name: "", digest: @digest}},
      %{configuration() | poll_interval_ms: 0},
      Map.put(configuration(), :unknown, true)
    ]

    Enum.each(invalid_configurations, fn configuration ->
      assert_raise ArgumentError, fn -> ScheduleRuntime.options!(configuration) end
    end)

    assert ScheduleDispatcher.run_once(:invalid) ==
             {:error, {:invalid_schedule_dispatcher, :options}}

    assert ScheduleDispatcher.run_once(worker_ref: "missing-policy") ==
             {:error, {:invalid_schedule_dispatcher, :options}}

    assert ScheduleDispatcher.run_once(
             custody: String,
             policy_resolver: fn _ -> :error end,
             worker_ref: "worker"
           ) == {:error, {:invalid_schedule_dispatcher, :settings}}

    assert ScheduleDispatcher.run_once(
             custody: Custody,
             lease_seconds: 0,
             policy_resolver: fn _ -> :error end,
             worker_ref: "worker"
           ) == {:error, {:invalid_schedule_dispatcher, :settings}}

    assert ScheduleWorker.init(poll_interval_ms: 0, dispatcher_options: []) ==
             {:stop, {:invalid_schedule_worker, :options}}
  end

  defp configuration do
    %{
      governed_operation_policy: %{name: "governed", digest: String.duplicate("b", 64)},
      poll_interval_ms: 25,
      read_only_policy: %{name: "read-only", digest: @digest},
      repositories: %{
        "octo/example" => %{name: "repository-write", digest: String.duplicate("c", 64)}
      },
      worker_ref: "schedule-worker:test"
    }
  end

  defp dispatcher_options do
    [
      custody: Custody,
      lease_seconds: 30,
      misfire_grace_seconds: 90,
      policy_resolver: fn _schedule -> {:ok, %{name: "read-only", digest: @digest}} end,
      retry_base_seconds: 5,
      retry_max_seconds: 20,
      worker_ref: "schedule-worker:test"
    ]
  end
end
