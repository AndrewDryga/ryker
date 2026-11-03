defmodule Ryker.ComposeWorkerLifecycleTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "ryker-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir}
  end

  # During the disk-pool cutover review (2026-11-03), release eval silently
  # discarded a rejected admission stop. A zero exit would let an operator
  # retire a worker that was still receiving new sessions.
  test "a rejected lifecycle command reports its reason and exits unsuccessfully", %{tmp_dir: dir} do
    for action <- ~w(stop-admission start-admission drain resume revoke) do
      {output, status} = invoke(dir, action, "rejected")
      assert status != 0, "#{action} reported success after rejection"
      assert output =~ "coop_worker_revoked"
    end
  end

  test "a successful lifecycle command preserves the controller report", %{tmp_dir: dir} do
    assert {output, 0} = invoke(dir, "stop-admission", "accepted")
    assert output == "{\"status\":\"admission_stopped\"}\n"
  end

  defp invoke(dir, action, worker) do
    File.write!(Path.join(dir, "compose.env"), "")
    release = Path.join(dir, "release.exs")

    File.write!(release, """
    defmodule Ryker.Release do
      def worker_lifecycle(_action, "rejected", _operator), do: {:error, :coop_worker_revoked}
      def worker_lifecycle(_action, "accepted", _operator) do
        IO.puts(~s({"status":"admission_stopped"}))
        {:ok, %{"status" => "admission_stopped"}}
      end
    end
    Code.eval_string(List.last(System.argv()))
    """)

    docker = Path.join(dir, "docker")
    File.write!(docker, "#!/bin/sh\nexec \"$LIFECYCLE_ELIXIR\" \"$LIFECYCLE_RELEASE\" \"$@\"\n")
    File.chmod!(docker, 0o700)

    System.cmd("/bin/sh", ["scripts/compose.sh", "worker-#{action}", worker, "operator:test"],
      stderr_to_stdout: true,
      env: [
        {"PATH", dir <> ":" <> System.fetch_env!("PATH")},
        {"RYKER_INSTALL_STATE", dir},
        {"LIFECYCLE_ELIXIR", System.find_executable("elixir")},
        {"LIFECYCLE_RELEASE", release},
        {"ERL_FLAGS", "+S 2:2"}
      ]
    )
  end
end
