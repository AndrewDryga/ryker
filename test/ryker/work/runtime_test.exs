defmodule Ryker.Work.RuntimeTest do
  use ExUnit.Case, async: true

  alias Ryker.Work.Runtime

  test "builds a bounded local worker pool without letting a slot choose episode authority" do
    child =
      Runtime.child_spec(
        concurrency: 3,
        platform_tools: ["list_runners", "find_actions"],
        poll_interval_ms: 500,
        receive_timeout_ms: 2_000,
        socket: "/tmp/coop.sock",
        state_tool_capabilities: [:schedules],
        state_tools_endpoint: "https://ryker.example/v1/state-tools/mcp",
        state_tools_secret: "controller-state-tools-secret",
        worker_ref: "ryker-work:vm-1"
      )

    assert child.id == Runtime
    assert {Runtime, :start_link, [configuration]} = child.start
    assert configuration[:concurrency] == 3

    assert {:ok, {_flags, workers}} = Runtime.init(configuration)
    assert length(workers) == 4

    assert Enum.map(workers, & &1.id) == [
             Ryker.Work.ActivitySyncWorker,
             {Ryker.Work.Worker, 1},
             {Ryker.Work.Worker, 2},
             {Ryker.Work.Worker, 3}
           ]

    [sync_worker | work_workers] = workers

    assert {Ryker.Work.ActivitySyncWorker, :start_link, [sync_options]} = sync_worker.start
    assert sync_options[:api] == Ryker.Coop.Client
    assert sync_options[:poll_interval_ms] == 500

    work_workers
    |> Enum.with_index(1)
    |> Enum.each(fn {worker, index} ->
      assert {Ryker.Work.Worker, :start_link, [options]} = worker.start
      assert options[:poll_interval_ms] == 500

      dispatcher = options[:dispatcher_options]
      assert dispatcher[:worker_ref] == "ryker-work:vm-1:slot-#{index}"
      assert dispatcher[:lease_seconds] == 300
      refute Keyword.has_key?(dispatcher[:executor_options], :policy)
      assert dispatcher[:executor_options][:api] == Ryker.Coop.Client
      assert dispatcher[:executor_options][:client].socket == "/tmp/coop.sock"
      assert dispatcher[:executor_options][:client].receive_timeout == 2_000

      assert dispatcher[:executor_options][:state_tools_endpoint] ==
               "https://ryker.example/v1/state-tools/mcp"

      assert dispatcher[:executor_options][:state_tools_secret] == "controller-state-tools-secret"
      assert dispatcher[:executor_options][:state_tool_capabilities] == [:schedules]
      assert dispatcher[:executor_options][:platform_tools] == ["list_runners", "find_actions"]
    end)
  end

  test "accepts the durable fleet API without retaining a direct Coop socket" do
    client = %Ryker.CoopFleet.Client{bridge: Ryker.CoopFleet.Bridge, bridge_options: []}

    settings =
      Runtime.options!(
        api: Ryker.CoopFleet.Client,
        client: client,
        receive_timeout_ms: 2_000,
        worker_ref: "ryker-work:fleet"
      )

    assert settings.api == Ryker.CoopFleet.Client
    assert settings.client == client
    assert settings.state_tool_capabilities == nil
    refute Map.has_key?(settings, :socket)
  end

  test "refuses a blocking Coop call that can outlive lease renewal" do
    assert_raise ArgumentError, ~r/receive_timeout_ms/, fn ->
      Runtime.child_spec(
        receive_timeout_ms: 100_000,
        socket: "/tmp/coop.sock",
        worker_ref: "ryker-work:vm-1"
      )
    end
  end

  test "refuses unknown or malformed local-pool configuration" do
    invalid = [
      :invalid,
      [socket: "/tmp/coop.sock", worker_ref: "duplicate", worker_ref: "duplicate"],
      %{socket: "/tmp/coop.sock"},
      %{socket: "tcp://coop.example", worker_ref: "ryker-work:vm-1"},
      %{concurrency: 0, socket: "/tmp/coop.sock", worker_ref: "ryker-work:vm-1"},
      %{poll_interval_ms: 0, socket: "/tmp/coop.sock", worker_ref: "ryker-work:vm-1"},
      %{
        platform_tools: ["list_runners", "list_runners"],
        socket: "/tmp/coop.sock",
        worker_ref: "ryker-work:vm-1"
      },
      %{
        socket: "/tmp/coop.sock",
        state_tool_capabilities: [:invented],
        state_tools_endpoint: "https://ryker.example/v1/state-tools/mcp",
        state_tools_secret: "controller-state-tools-secret",
        worker_ref: "ryker-work:vm-1"
      },
      %{
        socket: "/tmp/coop.sock",
        state_tools_endpoint: "https://ryker.example/v1/state-tools/mcp",
        worker_ref: "ryker-work:vm-1"
      },
      %{socket: "/tmp/coop.sock", surprise: true, worker_ref: "ryker-work:vm-1"}
    ]

    Enum.each(invalid, fn configuration ->
      assert_raise ArgumentError, fn -> Runtime.child_spec(configuration) end
    end)
  end
end
