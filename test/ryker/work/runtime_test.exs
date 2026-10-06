defmodule Ryker.Work.RuntimeTest do
  use ExUnit.Case, async: true
  alias Ryker.Work.Runtime

  @client %Ryker.CoopFleet.Client{bridge: Ryker.CoopFleet.Bridge, bridge_options: []}
  @adapter [api: Ryker.CoopFleet.Client, client: @client]

  test "builds a bounded worker pool without letting a slot choose episode authority" do
    child =
      Runtime.child_spec(
        @adapter ++
          [
            concurrency: 3,
            platform_tools: ["list_runners", "find_actions"],
            poll_interval_ms: 500,
            receive_timeout_ms: 2_000,
            state_tool_capabilities: [:schedules],
            state_tools_endpoint: "https://ryker.example/v1/state-tools/mcp",
            state_tools_secret: Ryker.Secret.new("controller-state-tools-secret"),
            worker_ref: "ryker-work:vm-1"
          ]
      )

    assert child.id == Runtime
    assert {Runtime, :start_link, [configuration]} = child.start
    assert configuration[:concurrency] == 3

    assert {:ok, {_flags, work_workers}} = Runtime.init(configuration)

    # The fleet client lists no session events, so nothing polls for them.
    assert Enum.map(work_workers, & &1.id) == [
             {Ryker.Work.Worker, 1},
             {Ryker.Work.Worker, 2},
             {Ryker.Work.Worker, 3}
           ]

    work_workers
    |> Enum.with_index(1)
    |> Enum.each(fn {worker, index} ->
      assert {Ryker.Work.Worker, :start_link, [options]} = worker.start
      assert options[:poll_interval_ms] == 500

      dispatcher = options[:dispatcher_options]
      assert dispatcher[:worker_ref] == "ryker-work:vm-1:slot-#{index}"
      assert dispatcher[:lease_seconds] == 300
      refute Keyword.has_key?(dispatcher[:executor_options], :policy)
      assert dispatcher[:executor_options][:api] == Ryker.CoopFleet.Client
      assert dispatcher[:executor_options][:client] == @client
      assert dispatcher[:executor_options][:max_block_ms] == 2_000

      assert dispatcher[:executor_options][:state_tools_endpoint] ==
               "https://ryker.example/v1/state-tools/mcp"

      assert dispatcher[:executor_options][:state_tools_secret] ==
               Ryker.Secret.new("controller-state-tools-secret")

      assert dispatcher[:executor_options][:state_tool_capabilities] == [:schedules]
      assert dispatcher[:executor_options][:platform_tools] == ["list_runners", "find_actions"]
    end)
  end

  # The sync worker woke four times a second in every release, whose fleet
  # client cannot list events (2026-10-04 review). A direct Coop client can.
  test "a Coop client that lists session events gets its activity read after each turn" do
    configuration =
      Runtime.options!(
        api: Ryker.TestSupport.FakeWorkCoopAPI,
        client: self(),
        poll_interval_ms: 500,
        state_tools_endpoint: "https://ryker.example/v1/state-tools/mcp",
        state_tools_secret: Ryker.Secret.new("controller-state-tools-secret"),
        worker_ref: "ryker-work:direct"
      )

    assert {:ok, {_flags, [sync | _workers]}} = Runtime.init(configuration)
    assert sync.id == Ryker.Work.ActivitySyncWorker
    assert {Ryker.Work.ActivitySyncWorker, :start_link, [sync_options]} = sync.start
    assert sync_options[:api] == Ryker.TestSupport.FakeWorkCoopAPI
    assert sync_options[:poll_interval_ms] == 500
  end

  test "work starts only on an explicit Coop adapter, never a local socket" do
    # Product builds place Work on the enrolled worker fleet. The local
    # Unix-socket client a `socket` used to build is eval-only and left the
    # release, so a configuration naming a socket, or no adapter at all, must
    # stop before supervision rather than at its first Coop call.
    for configuration <- [
          [socket: "/tmp/coop.sock", worker_ref: "ryker-work:vm-1"],
          [worker_ref: "ryker-work:vm-1"],
          [api: Ryker.CoopFleet.Client, worker_ref: "ryker-work:vm-1"],
          [api: Ryker.CoopFleet.Client, client: nil, worker_ref: "ryker-work:vm-1"],
          [api: nil, client: @client, worker_ref: "ryker-work:vm-1"]
        ] do
      assert_raise ArgumentError, fn -> Runtime.child_spec(configuration) end
    end

    settings = Runtime.options!(@adapter ++ [worker_ref: "ryker-work:fleet"])
    assert settings.api == Ryker.CoopFleet.Client
    assert settings.client == @client
    assert settings.state_tool_capabilities == nil
  end

  test "refuses a blocking Coop call that can outlive lease renewal" do
    assert_raise ArgumentError, ~r/receive_timeout_ms/, fn ->
      Runtime.child_spec(@adapter ++ [receive_timeout_ms: 100_000, worker_ref: "ryker-work:vm-1"])
    end
  end

  test "refuses unknown or malformed pool configuration" do
    adapter = Map.new(@adapter)

    invalid = [
      :invalid,
      @adapter ++ [worker_ref: "duplicate", worker_ref: "duplicate"],
      adapter,
      Map.merge(adapter, %{concurrency: 0, worker_ref: "ryker-work:vm-1"}),
      Map.merge(adapter, %{poll_interval_ms: 0, worker_ref: "ryker-work:vm-1"}),
      Map.merge(adapter, %{
        platform_tools: ["list_runners", "list_runners"],
        worker_ref: "ryker-work:vm-1"
      }),
      Map.merge(adapter, %{
        state_tool_capabilities: [:invented],
        state_tools_endpoint: "https://ryker.example/v1/state-tools/mcp",
        state_tools_secret: Ryker.Secret.new("controller-state-tools-secret"),
        worker_ref: "ryker-work:vm-1"
      }),
      Map.merge(adapter, %{
        state_tools_endpoint: "https://ryker.example/v1/state-tools/mcp",
        worker_ref: "ryker-work:vm-1"
      }),
      Map.merge(adapter, %{surprise: true, worker_ref: "ryker-work:vm-1"})
    ]

    Enum.each(invalid, fn configuration ->
      assert_raise ArgumentError, fn -> Runtime.child_spec(configuration) end
    end)
  end
end
