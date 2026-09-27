defmodule Ryker.Waits.EventWaitWorkerTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [eventually: 2]

  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Waits.EventWaitWorker
  alias Ryker.Work.Custody

  test "polls the durable due-wait queue without crashing when it is idle" do
    worker = start_supervised!({EventWaitWorker, poll_interval_ms: 10})
    Process.sleep(25)
    assert Process.alive?(worker)
    assert :ok = stop_supervised(EventWaitWorker)
  end

  test "rejects malformed poll configuration" do
    assert_raise ArgumentError, fn -> EventWaitWorker.start_link(poll_interval_ms: 0) end
    assert_raise ArgumentError, fn -> EventWaitWorker.start_link(%{unknown: true}) end
    assert_raise ArgumentError, fn -> EventWaitWorker.start_link(:invalid) end

    assert_raise ArgumentError, fn ->
      EventWaitWorker.start_link([{:poll_interval_ms, 1}, {:poll_interval_ms, 2}])
    end
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second;
  # the event-wait worker reconciled every wait once a second. It now sleeps
  # until a wait is announced or its timer falls due, so a wait a turn starts
  # has to wake it, and the timer has to fire on time rather than at the end
  # of a safety-net interval.
  test "a timer a turn starts while the worker is idle fires on time" do
    worker =
      start_supervised!({EventWaitWorker, idle_interval_ms: 60_000, poll_interval_ms: 60_000})

    # Its first poll found nothing, and its next timer is a minute away.
    _state = :sys.get_state(worker)

    record = timer_wait!("woken", "1s")

    refute answered?(record)
    assert eventually(fn -> answered?(record) end, 2_500)
  end

  test "a timer that falls due fires then, not at the safety-net interval" do
    record = timer_wait!("due", "1s")
    start_supervised!({EventWaitWorker, idle_interval_ms: 60_000, poll_interval_ms: 60_000})

    refute eventually(fn -> answered?(record) end, 400)
    assert eventually(fn -> answered?(record) end, 2_000)
  end

  defp answered?(record), do: Repo.get!(Record, record.id).status == :answered

  # A turn that asks to be woken after `delay`, with a hard deadline far off.
  defp timer_wait!(suffix, delay) do
    now = Repo.now!()
    deadline = DateTime.add(now, 900, :second)
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:event-wait-worker:#{suffix}:#{episode_id}"

    {:ok, transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode_id,
          episode_key: "event-wait-worker:#{suffix}:#{episode_id}",
          native_input_id: "event-wait-worker-input:#{suffix}:#{episode_id}",
          occurred_at: DateTime.add(now, -11, :second),
          turn_ref: turn_ref
        })
      )

    {:ok, _session} = Custody.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("worker:event-wait-worker:#{suffix}", 60, :work)

    {:ok, record} =
      Records.create(Records.token(claim.turn), "wait-timer", "event_wait", %{
        "deadline_at" => DateTime.to_iso8601(deadline),
        "event_matcher" => %{
          "delay" => delay,
          "on_timeout" => "Report the gap.",
          "type" => "after"
        },
        "kind" => "after",
        "verification" => "Check the deployment again."
      })

    {:ok, _waiting} =
      Episodes.apply(
        EpisodeFixtures.start_wait(%{
          deadline_at: deadline,
          episode_key: transition.episode.key,
          expected_turn_ref: turn_ref,
          kind: :event,
          occurred_at: DateTime.add(now, -10, :second),
          wait_ref: record.ref
        })
      )

    record
  end
end
