defmodule Responder.CoopFleet.OperatorTaskTest do
  use Responder.DataCase, async: false

  alias Mix.Tasks.Responder.CoopWorker
  alias Responder.CoopFleet.{ControlPlane, Worker}

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Shell.Process.flush()

    on_exit(fn ->
      Mix.Shell.Process.flush()
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "operator enrollment commands mint one bounded token with default or explicit TTL" do
    CoopWorker.run(["enroll", "worker-default", "workspace-main", "operator:andrew"])
    assert {:mix_shell, :info, [default_json]} = receive_shell!()
    assert %{"token" => default_token} = Jason.decode!(default_json)
    assert is_binary(default_token)

    CoopWorker.run(["enroll", "worker-short", "workspace-main", "operator:andrew", "60"])
    assert {:mix_shell, :info, [short_json]} = receive_shell!()
    assert %{"token" => short_token} = Jason.decode!(short_json)
    refute short_token == default_token
  end

  test "operator enrollment rejects invalid invocation and typed custody errors" do
    assert_raise Mix.Error, ~r/usage: mix responder.coop_worker/, fn -> CoopWorker.run([]) end

    assert_raise Mix.Error, ~r/usage: mix responder.coop_worker/, fn ->
      CoopWorker.run(["enroll", "worker", "workspace", "operator", "one-minute"])
    end

    assert_raise Mix.Error, ~r/worker enrollment failed/, fn ->
      CoopWorker.run(["enroll", "", "workspace", "operator", "60"])
    end
  end

  test "operator commands drain, resume, and revoke one exact worker" do
    certificate = "operator-worker-certificate"
    digest = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    assert {:ok, %Worker{}} =
             ControlPlane.authorize_worker("worker-ops", "workspace-main", digest)

    CoopWorker.run(["drain", "worker-ops", "operator:andrew"])
    assert {:mix_shell, :info, [drain_json]} = receive_shell!()
    assert %{"status" => "draining", "worker_id" => "worker-ops"} = Jason.decode!(drain_json)

    CoopWorker.run(["resume", "worker-ops", "operator:andrew"])
    assert {:mix_shell, :info, [resume_json]} = receive_shell!()
    assert %{"status" => "resumed", "worker_id" => "worker-ops"} = Jason.decode!(resume_json)

    CoopWorker.run(["revoke", "worker-ops", "operator:security"])
    assert {:mix_shell, :info, [revoke_json]} = receive_shell!()
    assert %{"status" => "revoked", "worker_id" => "worker-ops"} = Jason.decode!(revoke_json)
  end

  defp receive_shell! do
    receive do
      {:mix_shell, :info, _message} = event -> event
    after
      100 -> flunk("expected Mix shell output")
    end
  end
end
