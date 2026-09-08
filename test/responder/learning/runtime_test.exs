defmodule Responder.Learning.RuntimeTest do
  use ExUnit.Case, async: true
  alias Responder.Learning.{Runtime, Worker}

  @config %{
    api: Responder.TestSupport.FakeCoopAPI,
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
end
