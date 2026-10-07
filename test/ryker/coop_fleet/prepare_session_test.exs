defmodule Ryker.CoopFleet.PrepareSessionTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Admission.ReadySessions
  alias Ryker.CoopFleet.{Client, Command, ControlPlane}
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Repo

  @policy %{name: "admission-read-only", digest: String.duplicate("a", 64)}
  @worker "worker-prepare"
  @coop_session_id "coop-ready-prepare"

  # Live install, 2026-09-27: Coop spent most of each 12–18 s routing turn
  # starting the box and the agent. A session kept ready is now prepared on
  # its worker ahead of any message. Coop answers a prepare only once the
  # agent is running, after waiting for a free runtime slot, and the worker
  # runs one command at a time, so the prepare goes out only to a worker
  # with nothing else to do, carries the revision Coop reports, and is never
  # sent twice.
  test "a ready session is prepared through its worker only while the worker is idle, and once" do
    authorize!()
    poll!("hello", capacity(4, 4))
    session = ready_session!()
    key = "ryker:admission-ready:prepare:#{session.id}"
    parent = self()

    poll!("busy", capacity(3, 4))

    assert {:error, :coop_worker_busy} =
             Client.prepare_session(client!(fn -> :ok end), @coop_session_id, key)

    assert commands(session) == []

    poll!("idle", capacity(4, 4))

    task =
      Task.async(fn ->
        receive do
          :start -> :ok
        end

        Client.prepare_session(
          client!(fn ->
            send(parent, :bridge_waiting)

            receive do
              :bridge_continue -> :ok
            end
          end),
          @coop_session_id,
          key
        )
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :start)

    # Coop is asked for the session's current revision first. The task writes
    # and reads the database before it waits, which took over a second while a
    # gate ran at load 30 (2026-10-08).
    assert_receive :bridge_waiting, 5_000
    assert %{"payload" => %{"method" => "GET", "path" => path}} = read = deliver!("read")
    assert path == "/v1/sessions/#{@coop_session_id}"
    complete!("read", read, %{"id" => @coop_session_id, "revision" => 3, "state" => "open"})
    send(task.pid, :bridge_continue)

    assert_receive :bridge_waiting, 5_000
    assert %{"payload" => request} = prepare = deliver!("prepare")
    assert request["method"] == "POST"
    assert request["path"] == "/v1/sessions/#{@coop_session_id}/prepare"
    assert request["body"] == %{"expected_revision" => 3}
    assert prepare["idempotency_key"] == key
    complete!("prepare", prepare, %{"id" => @coop_session_id, "revision" => 3, "state" => "open"})
    send(task.pid, :bridge_continue)

    assert {:ok, %{"id" => @coop_session_id}} = Task.await(task)

    # Asked again, the fleet answers from the prepare it recorded.
    poll!("after", capacity(3, 4))

    assert {:ok, %{"id" => @coop_session_id}} =
             Client.prepare_session(client!(fn -> :ok end), @coop_session_id, key)

    assert Enum.map(commands(session), & &1.kind) == ["get_session", "prepare_session"]
  end

  defp client!(wait) do
    assert {:ok, client} =
             Client.new(
               capability_names: ["controller-tools"],
               max_waits: 5,
               poll_interval_ms: 1,
               wait: wait,
               workspace_ref: "workspace-main"
             )

    client
  end

  # A session kept ready: reserved, pinned, placed on the worker, and open.
  defp ready_session! do
    assert {:ok, reserved} = ReadySessions.reserve(@policy, 1)
    reserved = WorkerJob.pin!(reserved)

    assert {:ok, _placement} =
             ControlPlane.place_session(
               reserved.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: nil,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, ready} = ReadySessions.mark_ready(reserved, @coop_session_id)
    ready
  end

  defp commands(session) do
    Repo.all(
      from(command in Command,
        where: command.session_id == ^session.id,
        order_by: [asc: command.inserted_at, asc: command.id]
      )
    )
  end

  defp deliver!(suffix) do
    assert {:ok, %{"commands" => [command]}} = poll!("deliver:#{suffix}", capacity(4, 4))
    command
  end

  defp complete!(suffix, command, body) do
    result = %{
      "command_id" => command["command_id"],
      "error" => nil,
      "operation_key" => command["idempotency_key"],
      "resource" => %{"status" => 200, "body" => body},
      "state" => "succeeded"
    }

    assert {:ok, %{"acknowledged_result_command_ids" => [_id]}} =
             poll!("complete:#{suffix}", capacity(4, 4), command_results: [result])
  end

  defp authorize! do
    certificate = digest(@worker)

    assert {:ok, _worker} =
             CoopWorkers.authorize(@worker, "workspace-main", certificate)
  end

  defp poll!(suffix, capacity, options \\ []) do
    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(@worker, %{
               "acknowledged_command_ids" => [],
               "command_results" => Keyword.get(options, :command_results, []),
               "event_batches" => [],
               "poll_ref" => "poll:#{@worker}:#{suffix}",
               "version" => 2,
               "worker" => %{
                 "build_version" => "coop-test",
                 "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
                 "capacity" => capacity,
                 "clock_at" => DateTime.to_iso8601(Repo.now!()),
                 "id" => @worker,
                 "protocol_version" => "2",
                 "sandbox_digest" => String.duplicate("a", 64),
                 "state" => "eligible",
                 "workspace_ref" => "workspace-main"
               }
             })

    {:ok, response}
  end

  defp capacity(free, total) do
    %{
      "cooldown_until" => nil,
      "session_slots_free" => free,
      "session_slots_total" => total,
      "state" => "eligible",
      "turn_slots_free" => free,
      "turn_slots_total" => total,
      "workspace_slots_free" => free,
      "workspace_slots_total" => total
    }
  end
end
