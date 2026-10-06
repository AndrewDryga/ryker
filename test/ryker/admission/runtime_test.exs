defmodule Ryker.Admission.RuntimeTest do
  use ExUnit.Case, async: true
  alias Ryker.Admission.{Runtime, Worker}

  defmodule FleetAPI do
    def get_session(_client, _session_id), do: {:error, :not_used}
  end

  @client %{transport: :fleet}
  @identity [
    policy: "admission-read-only",
    policy_digest: String.duplicate("a", 64),
    worker_ref: "ryker:local"
  ]

  test "builds a bounded admission pool on the trusted fleet adapter" do
    child =
      Runtime.child_spec(
        [api: FleetAPI, client: @client, poll_interval_ms: 500, receive_timeout_ms: 2_000] ++
          @identity
      )

    assert child.id == Runtime
    assert {Runtime, :start_link, [configuration]} = child.start
    assert child.type == :supervisor
    assert {:ok, {_flags, workers}} = Runtime.init(configuration)
    assert length(workers) == 4
    assert Enum.map(workers, & &1.id) == Enum.map(1..4, &{Worker, &1})
    assert {Worker, :start_link, [options]} = hd(workers).start
    assert options[:poll_interval_ms] == 500

    dispatcher = options[:dispatcher_options]
    assert dispatcher[:worker_ref] == "ryker:local:slot-1"
    assert dispatcher[:lease_seconds] == 300

    executor = dispatcher[:executor_options]
    assert executor[:policy] == "admission-read-only"
    assert executor[:policy_digest] == String.duplicate("a", 64)
    assert executor[:maximum_elapsed_ms] == 30_000
    assert executor[:api] == FleetAPI
    assert executor[:client] == @client
    assert is_function(executor[:prepare_execution_session], 2)
    assert is_function(executor[:bind_execution_session], 2)
    assert is_function(executor[:settle_execution_session], 2)
  end

  test "admission starts only on an explicit Coop adapter, never a local socket" do
    # Product builds place admission on the enrolled worker fleet. The local
    # Unix-socket client a `socket` used to build is eval-only and left the
    # release, so a configuration naming a socket, or no adapter at all, must
    # stop before supervision rather than at its first Coop call.
    for configuration <- [
          [socket: "/tmp/coop.sock"] ++ @identity,
          @identity,
          [api: FleetAPI] ++ @identity,
          [api: FleetAPI, client: nil] ++ @identity,
          [api: nil, client: @client] ++ @identity
        ] do
      assert_raise ArgumentError, fn -> Runtime.child_spec(configuration) end
    end
  end

  test "refuses a Coop timeout that can outlive the admission lease heartbeat" do
    # A single blocking HTTP call longer than the heartbeat safety window can
    # let another worker reclaim the same input while the first is still live.
    assert_raise ArgumentError, ~r/receive_timeout_ms/, fn ->
      Runtime.child_spec(
        [api: FleetAPI, client: @client, receive_timeout_ms: 100_001] ++ @identity
      )
    end
  end

  test "refuses malformed trusted configuration before supervision starts" do
    invalid_configurations = [
      [
        api: FleetAPI,
        client: @client,
        concurrency: 33,
        policy: "admission",
        policy_digest: String.duplicate("a", 64),
        worker_ref: "worker"
      ],
      [
        api: FleetAPI,
        client: @client,
        concurrency: 0,
        policy: "admission",
        policy_digest: String.duplicate("a", 64),
        worker_ref: "worker"
      ],
      :not_a_configuration,
      [
        api: FleetAPI,
        client: @client,
        policy: "admission-read-only",
        policy: "duplicate",
        worker_ref: "ryker:local"
      ],
      [api: FleetAPI, client: @client, surprise: true] ++ @identity,
      %{api: FleetAPI, client: @client, policy: "admission-read-only"},
      %{
        api: FleetAPI,
        client: @client,
        policy: " ",
        policy_digest: String.duplicate("a", 64),
        worker_ref: "ryker:local"
      },
      %{
        api: FleetAPI,
        client: @client,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        decision_timeout_ms: 0,
        worker_ref: "ryker:local"
      },
      %{
        api: FleetAPI,
        client: @client,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 0,
        worker_ref: "ryker:local"
      },
      %{
        api: FleetAPI,
        client: @client,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        worker_ref: :not_a_reference
      },
      %{
        api: FleetAPI,
        client: @client,
        policy: "admission-read-only",
        policy_digest: String.duplicate("A", 64),
        worker_ref: "ryker:local"
      }
    ]

    Enum.each(invalid_configurations, fn configuration ->
      assert_raise ArgumentError, fn -> Runtime.child_spec(configuration) end
    end)
  end
end
