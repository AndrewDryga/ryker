defmodule Responder.Work.RuntimeTest do
  use ExUnit.Case, async: true

  alias Responder.Work.Runtime

  test "builds a bounded local worker pool without letting a slot choose episode authority" do
    child =
      Runtime.child_spec(
        concurrency: 3,
        poll_interval_ms: 500,
        receive_timeout_ms: 2_000,
        socket: "/tmp/coop.sock",
        worker_ref: "responder-work:vm-1"
      )

    assert child.id == Runtime
    assert {Runtime, :start_link, [configuration]} = child.start
    assert configuration[:concurrency] == 3

    assert {:ok, {_flags, workers}} = Runtime.init(configuration)
    assert length(workers) == 3

    assert Enum.map(workers, & &1.id) == [
             {Responder.Work.Worker, 1},
             {Responder.Work.Worker, 2},
             {Responder.Work.Worker, 3}
           ]

    workers
    |> Enum.with_index(1)
    |> Enum.each(fn {worker, index} ->
      assert {Responder.Work.Worker, :start_link, [options]} = worker.start
      assert options[:poll_interval_ms] == 500

      dispatcher = options[:dispatcher_options]
      assert dispatcher[:worker_ref] == "responder-work:vm-1:slot-#{index}"
      assert dispatcher[:lease_seconds] == 300
      refute Keyword.has_key?(dispatcher[:executor_options], :policy)
      assert dispatcher[:executor_options][:client].socket == "/tmp/coop.sock"
      assert dispatcher[:executor_options][:client].receive_timeout == 2_000
    end)
  end

  test "refuses a blocking Coop call that can outlive lease renewal" do
    assert_raise ArgumentError, ~r/receive_timeout_ms/, fn ->
      Runtime.child_spec(
        receive_timeout_ms: 100_000,
        socket: "/tmp/coop.sock",
        worker_ref: "responder-work:vm-1"
      )
    end
  end

  test "refuses unknown or malformed local-pool configuration" do
    invalid = [
      :invalid,
      [socket: "/tmp/coop.sock", worker_ref: "duplicate", worker_ref: "duplicate"],
      %{socket: "/tmp/coop.sock"},
      %{socket: "tcp://coop.example", worker_ref: "responder-work:vm-1"},
      %{concurrency: 0, socket: "/tmp/coop.sock", worker_ref: "responder-work:vm-1"},
      %{poll_interval_ms: 0, socket: "/tmp/coop.sock", worker_ref: "responder-work:vm-1"},
      %{socket: "/tmp/coop.sock", surprise: true, worker_ref: "responder-work:vm-1"}
    ]

    Enum.each(invalid, fn configuration ->
      assert_raise ArgumentError, fn -> Runtime.child_spec(configuration) end
    end)
  end
end
