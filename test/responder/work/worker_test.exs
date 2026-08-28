defmodule Responder.Work.WorkerTest do
  use Responder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.TestSupport.FakeWorkCoopAPI, as: FakeAPI
  alias Responder.Work.{Custody, Turn, Worker}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "polls durable work and reaches a validated delivery intent" do
    episode_id = create_episode!("worker-success")
    {:ok, fake} = FakeAPI.start_link([reply("Handled by the local worker pool.")])

    worker = start_supervised!({Worker, worker_options(fake, "work-worker:success")})

    assert eventually(fn ->
             case Responder.Repo.get_by(Turn, episode_id: episode_id) do
               %Turn{status: :delivery_pending, lease_ref: nil} -> true
               _other -> false
             end
           end)

    assert Process.alive?(worker)
    assert FakeAPI.state(fake).submit_count == 1
    assert :ok = stop_supervised(Worker)
  end

  test "keeps running after work enters durable remote-stop custody" do
    episode_id = create_episode!("worker-blocked")

    worker =
      start_supervised!(
        {Worker,
         [
           dispatcher_options: [
             executor: __MODULE__.BlockedExecutor,
             executor_options: [],
             lease_seconds: 60,
             worker_ref: "work-worker:blocked"
           ],
           poll_interval_ms: 10
         ]}
      )

    assert eventually(fn ->
             case Responder.Repo.get_by(Turn, episode_id: episode_id) do
               %Turn{status: :cancel_pending, lease_ref: nil} -> true
               _other -> false
             end
           end)

    assert Process.alive?(worker)
    assert :ok = stop_supervised(Worker)
  end

  test "keeps running while transient work is deferred" do
    episode_id = create_episode!("worker-deferred")

    worker =
      start_supervised!(
        {Worker,
         [
           dispatcher_options: [
             executor: __MODULE__.DeferredExecutor,
             executor_options: [],
             lease_seconds: 60,
             worker_ref: "work-worker:deferred"
           ],
           poll_interval_ms: 10
         ]}
      )

    assert eventually(fn ->
             case Responder.Repo.get_by(Turn, episode_id: episode_id) do
               %Turn{status: :pending, lease_ref: nil, next_attempt_at: %DateTime{}} -> true
               _other -> false
             end
           end)

    assert Process.alive?(worker)
    assert :ok = stop_supervised(Worker)
  end

  test "one long turn does not prevent another pool slot from processing a short episode" do
    long_episode_id = create_episode!("pool-long")
    short_episode_id = create_episode!("pool-short")

    base = [
      dispatcher_options: [
        executor: __MODULE__.ConcurrentExecutor,
        executor_options: [long_episode_id: long_episode_id, test_pid: self()],
        lease_seconds: 60,
        worker_ref: "work-worker:pool"
      ],
      poll_interval_ms: 10
    ]

    long_worker =
      start_supervised!(Supervisor.child_spec({Worker, base}, id: :work_pool_long_slot))

    assert_receive {:long_claimed, ^long_episode_id, ^long_worker}, 1_000

    short_worker =
      start_supervised!(Supervisor.child_spec({Worker, base}, id: :work_pool_short_slot))

    assert_receive {:short_processed, ^short_episode_id, ^short_worker}, 1_000

    send(long_worker, :release_long_turn)
    assert_receive {:long_released, ^long_episode_id}, 1_000
    assert :ok = stop_supervised(:work_pool_long_slot)
    assert :ok = stop_supervised(:work_pool_short_slot)
  end

  test "an invalid dispatcher configuration is logged without crashing the worker" do
    log =
      capture_log(fn ->
        worker =
          start_supervised!(
            {Worker,
             [
               dispatcher_options: [worker_ref: "work-worker:invalid", max_attempts: 0],
               poll_interval_ms: 10
             ]}
          )

        Process.sleep(30)
        assert Process.alive?(worker)
        assert :ok = stop_supervised(Worker)
      end)

    assert log =~ "episode work dispatcher failed"
  end

  defmodule BlockedExecutor do
    @moduledoc false
    def run(_claim, _options), do: {:error, {:work_execution_blocked, :operator_required}}
  end

  defmodule DeferredExecutor do
    @moduledoc false
    def run(_claim, _options), do: {:error, {:coop_timeout, :turn}}
  end

  defmodule ConcurrentExecutor do
    @moduledoc false

    alias Responder.Work.Custody

    def run(claim, options) do
      test_pid = Keyword.fetch!(options, :test_pid)
      long_episode_id = Keyword.fetch!(options, :long_episode_id)

      completion =
        if claim.episode.id == long_episode_id do
          send(test_pid, {:long_claimed, claim.episode.id, self()})

          receive do
            :release_long_turn -> {:long_released, claim.episode.id}
          end
        else
          {:short_processed, claim.episode.id, self()}
        end

      assert_deferred(claim)
      send(test_pid, completion)
      {:ok, %{episode_id: claim.episode.id}}
    end

    defp assert_deferred(claim) do
      {:ok, _turn} =
        Custody.defer(
          claim.episode.id,
          claim.turn.turn_ref,
          claim.lease_ref,
          60,
          "test_executor_yield",
          "The concurrency fixture released its claim."
        )

      :ok
    end
  end

  defp create_episode!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        actor_ref: "slack:user:U-stage3",
        episode_id: id,
        episode_key: "work-worker:#{suffix}:#{id}",
        native_input_id: "slack-message:#{suffix}:#{id}",
        occurred_at: @now,
        payload: %{"text" => "Please handle #{suffix}."},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))

    id
  end

  defp worker_options(fake, worker_ref) do
    [
      dispatcher_options: [
        executor_options: [
          api: FakeAPI,
          client: fake,
          max_block_ms: 1_000,
          max_polls: 20,
          monotonic_ms: fn -> 0 end,
          now: fn -> @now end,
          poll_interval_ms: 0,
          sleep: fn _milliseconds -> :ok end
        ],
        lease_seconds: 60,
        worker_ref: worker_ref
      ],
      poll_interval_ms: 10
    ]
  end

  defp reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
    })
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(5)
      eventually(predicate, attempts - 1)
    end
  end
end
