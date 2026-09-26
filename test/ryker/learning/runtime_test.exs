defmodule Ryker.Learning.RuntimeTest do
  use ExUnit.Case, async: true
  alias Ryker.Learning.{Runtime, Worker}

  @config %{
    api: Ryker.TestSupport.FakeCoopAPI,
    client: :test,
    policy: "learning-no-tools",
    policy_digest: String.duplicate("a", 64),
    worker_ref: "host:learning"
  }

  test "trusted configuration builds one bounded worker without a second execution owner" do
    assert %{id: Runtime} = Runtime.child_spec(@config)
    assert {:ok, {_flags, [worker]}} = Runtime.init(@config)
    assert {Worker, :start_link, [settings]} = worker.start
    assert settings.worker_ref == "host:learning:slot-1"
    assert settings.batch_size == 16
    assert settings.lease_seconds == 300
    assert settings.quiet_seconds == 10
    assert settings.maximum_delay_seconds == 60
    assert settings.execution_timeout_seconds == 600
  end

  test "learning refuses unbounded or ambiguous runtime configuration" do
    for change <- [
          %{concurrency: 0},
          %{concurrency: 9},
          %{batch_size: 17},
          %{maximum_delay_seconds: 1, quiet_seconds: 10},
          %{receive_timeout_ms: 30_001},
          %{policy_digest: "invented"},
          %{socket: "/tmp/other.sock"},
          %{worker_ref: ""},
          %{unknown: true}
        ] do
      assert_raise ArgumentError, fn -> Runtime.options!(Map.merge(@config, change)) end
    end
  end

  test "learning starts only on an explicit Coop adapter, never a local socket" do
    # Product builds place learning on the enrolled worker fleet. The local
    # Unix-socket client a `socket` used to build is eval-only and left the
    # release, so a configuration naming a socket, or no adapter at all, must
    # stop before supervision rather than at its first Coop call.
    adapterless = Map.drop(@config, [:api, :client])

    for invalid <- [
          Map.put(adapterless, :socket, "/tmp/ryker-learning-test.sock"),
          adapterless,
          Map.put(adapterless, :api, Ryker.TestSupport.FakeCoopAPI),
          %{@config | client: nil},
          %{@config | api: nil}
        ] do
      assert_raise ArgumentError, fn -> Runtime.options!(invalid) end
    end

    settings = Runtime.options!(@config)
    assert settings.api == Ryker.TestSupport.FakeCoopAPI
    assert settings.client == :test
  end
end
