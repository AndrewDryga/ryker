defmodule Responder.Admission.RuntimeTest do
  use ExUnit.Case, async: true

  alias Responder.Admission.{Runtime, Worker}

  defmodule FleetAPI do
    def get_session(_client, _session_id), do: {:error, :not_used}
  end

  test "builds one worker from trusted Coop configuration" do
    child =
      Runtime.child_spec(
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 500,
        receive_timeout_ms: 2_000,
        socket: "/tmp/coop.sock",
        worker_ref: "responder:local"
      )

    assert child.id == Runtime
    assert {Worker, :start_link, [options]} = child.start
    assert options[:poll_interval_ms] == 500

    dispatcher = options[:dispatcher_options]
    assert dispatcher[:worker_ref] == "responder:local"
    assert dispatcher[:lease_seconds] == 300
    assert dispatcher[:executor_options][:policy] == "admission-read-only"
    assert dispatcher[:executor_options][:policy_digest] == String.duplicate("a", 64)
    assert dispatcher[:executor_options][:client].socket == "/tmp/coop.sock"
    assert dispatcher[:executor_options][:client].receive_timeout == 2_000
  end

  test "builds product admission on the durable fleet adapter instead of a local socket" do
    client = %{transport: :fleet}

    child =
      Runtime.child_spec(
        api: FleetAPI,
        client: client,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 500,
        receive_timeout_ms: 2_000,
        worker_ref: "responder:fleet"
      )

    assert {Worker, :start_link, [options]} = child.start
    executor = options[:dispatcher_options][:executor_options]
    assert executor[:api] == FleetAPI
    assert executor[:client] == client
    assert is_function(executor[:prepare_execution_session], 2)
    assert is_function(executor[:bind_execution_session], 2)
    assert is_function(executor[:settle_execution_session], 2)
  end

  test "refuses a Coop timeout that can outlive the admission lease heartbeat" do
    # A single blocking HTTP call longer than the heartbeat safety window can
    # let another worker reclaim the same input while the first is still live.
    assert_raise ArgumentError, ~r/receive_timeout_ms/, fn ->
      Runtime.child_spec(
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        receive_timeout_ms: 100_001,
        socket: "/tmp/coop.sock",
        worker_ref: "responder:local"
      )
    end
  end

  test "refuses unknown fields and invalid sockets before supervision starts" do
    assert_raise ArgumentError, fn ->
      Runtime.child_spec(
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        socket: "tcp://coop.example",
        worker_ref: "responder:local"
      )
    end

    assert_raise ArgumentError, fn ->
      Runtime.child_spec(
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        socket: "/tmp/coop.sock",
        surprise: true,
        worker_ref: "responder:local"
      )
    end
  end

  test "refuses malformed trusted configuration before supervision starts" do
    invalid_configurations = [
      :not_a_configuration,
      [
        policy: "admission-read-only",
        policy: "duplicate",
        socket: "/tmp/coop.sock",
        worker_ref: "responder:local"
      ],
      %{policy: "admission-read-only", socket: "/tmp/coop.sock"},
      %{
        policy: " ",
        policy_digest: String.duplicate("a", 64),
        socket: "/tmp/coop.sock",
        worker_ref: "responder:local"
      },
      %{
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 0,
        socket: "/tmp/coop.sock",
        worker_ref: "responder:local"
      },
      %{
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        socket: "/tmp/coop.sock",
        worker_ref: :not_a_reference
      },
      %{
        policy: "admission-read-only",
        policy_digest: String.duplicate("A", 64),
        socket: "/tmp/coop.sock",
        worker_ref: "responder:local"
      }
    ]

    Enum.each(invalid_configurations, fn configuration ->
      assert_raise ArgumentError, fn -> Runtime.child_spec(configuration) end
    end)
  end
end
