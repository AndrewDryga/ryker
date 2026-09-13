defmodule Ryker.State.EventWaitWorkerTest do
  use Ryker.DataCase, async: false

  alias Ryker.State.EventWaitWorker

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
end
