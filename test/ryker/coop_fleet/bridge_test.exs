defmodule Ryker.CoopFleet.BridgeTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1, eventually: 1]
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CoopFleet.Bodies
  alias Ryker.CoopFleet.{Bridge, Command, ControlPlane, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Repo
  alias Ryker.Retention
  alias Ryker.Work

  @policy_digest String.duplicate("b", 64)

  # Twenty create identities reused one placement and kept roughly 96,000
  # receipt acknowledgements failing. A proven failed create spends both identities.
  test "a proven absent create retries on a new placement and preserves both receipts" do
    worker = "worker-create-retry"
    ready_worker!(worker)
    session = session!()
    first_key = "ryker:work:create:#{session.id}:g1"
    second_key = "ryker:work:create:#{session.id}:g2"
    started = create_operation("operation-original", "running")
    failed = put_in(started, ["operation", "state"], "failed")

    assert {:ok, ^started} =
             bridge_result!(
               session,
               worker,
               "create_session",
               create_payload(session),
               first_key,
               started
             )

    first = Repo.get_by!(Command, idempotency_key: first_key)

    assert {:ok, ^failed} =
             bridge_result!(
               session,
               worker,
               "reconcile_operation",
               %{"operation_key" => first_key},
               Command.read_key("reconcile_operation"),
               failed
             )

    assert Retention.Creation.resolve(session) == {:ok, :absent}
    session = session |> Work.Session.Changeset.advance_create(2) |> Repo.update!()
    next = create_operation("operation-next", "running")

    assert {:ok, ^next} =
             bridge_result!(
               session,
               worker,
               "create_session",
               create_payload(session),
               second_key,
               next
             )

    second = Repo.get_by!(Command, idempotency_key: second_key)
    assert second.placement_generation == first.placement_generation + 1
    refute second.placement_id == first.placement_id
    assert Repo.get!(Placement, first.placement_id).state == :replaced
    assert Repo.get!(Placement, second.placement_id).state == :active
    assert Repo.get!(Command, first.id).result == first.result
    assert second.payload == first.payload

    for {key, response} <- [{first_key, started}, {second_key, next}] do
      assert {:ok, ^response} =
               Bridge.execute(session, "create_session", create_payload(session), key,
                 capability_names: ["controller-tools"],
                 workspace_ref: "workspace-main",
                 wait: fn -> flunk("a saved create was sent again") end
               )
    end

    assert length(Repo.all(Placement.Query.by_session_id(session.id))) == 2
  end

  for state <- ["running", "uncertain", "succeeded"] do
    @create_state state
    test "a #{@create_state} create cannot be replaced just because the caller changed its key" do
      worker = "worker-unresolved-#{@create_state}"
      ready_worker!(worker)
      session = session!()
      old_key = "ryker:work:create:#{session.id}:g1"
      next_key = "ryker:work:create:#{session.id}:g2"
      operation = create_operation("operation-unresolved", @create_state)

      assert {:ok, ^operation} =
               bridge_result!(
                 session,
                 worker,
                 "create_session",
                 create_payload(session),
                 old_key,
                 operation
               )

      old = Repo.get_by!(Command, idempotency_key: old_key)
      session = session |> Work.Session.Changeset.advance_create(2) |> Repo.update!()

      assert {:error, {:coop_session_create_unresolved, session_id}} =
               Bridge.execute(session, "create_session", create_payload(session), next_key,
                 capability_names: ["controller-tools"],
                 workspace_ref: "workspace-main",
                 wait: fn -> flunk("an unresolved create was delivered again") end
               )

      assert session_id == session.id
      refute Repo.get_by(Command, idempotency_key: next_key)
      assert Repo.get!(Placement, old.placement_id).state == :active
      assert length(Repo.all(Placement.Query.by_session_id(session.id))) == 1
    end
  end

  test "a failed create keeps its placement when no worker can take its replacement" do
    worker = "worker-no-retry-capacity"
    ready_worker!(worker)
    session = session!()
    key = "ryker:work:create:#{session.id}:g1"
    failed = create_operation("operation-absent", "failed")

    assert {:ok, ^failed} =
             bridge_result!(
               session,
               worker,
               "create_session",
               create_payload(session),
               key,
               failed
             )

    first = Repo.get_by!(Command, idempotency_key: key)

    full =
      Enum.reduce(
        ~w(session_slots_free turn_slots_free workspace_slots_free),
        poll(worker, "full"),
        fn slot, value -> put_in(value, ["worker", "capacity", slot], 0) end
      )

    assert {:ok, _} = ControlPlane.handle_poll_certificate(worker, full)
    session = session |> Work.Session.Changeset.advance_create(2) |> Repo.update!()
    next_key = "ryker:work:create:#{session.id}:g2"

    assert {:error, {:coop_worker_capacity_unavailable, session_id}} =
             Bridge.execute(session, "create_session", create_payload(session), next_key,
               capability_names: ["controller-tools"],
               workspace_ref: "workspace-main",
               wait: fn -> flunk("no capacity") end
             )

    assert session_id == session.id
    refute Repo.get_by(Command, idempotency_key: next_key)
    assert Repo.get!(Placement, first.placement_id).state == :active
    assert length(Repo.all(Placement.Query.by_session_id(session.id))) == 1
  end

  defp ready_worker!(worker) do
    assert {:ok, _} = CoopWorkers.authorize(worker, "workspace-main", digest(worker))
    assert {:ok, _} = ControlPlane.handle_poll_certificate(worker, poll(worker, "hello"))
  end

  defp create_operation(id, "succeeded"),
    do: %{
      "operation" => %{
        "id" => id,
        "method" => "CreateRemoteSession",
        "state" => "succeeded",
        "resource_type" => "session",
        "resource_id" => "remote-created"
      }
    }

  defp create_operation(id, state),
    do: %{"operation" => %{"id" => id, "method" => "CreateRemoteSession", "state" => state}}

  defp create_payload(session),
    do: %{
      "external_ref" => Work.Session.coop_task_ref(session),
      "job" => session.worker_job_document,
      "job_digest" => session.worker_job_digest
    }

  defp bridge_result!(session, worker, kind, payload, key, body) do
    Bridge.execute(session, kind, payload, key,
      capability_names: ["controller-tools"],
      workspace_ref: "workspace-main",
      max_waits: 2,
      poll_interval_ms: 1,
      wait: fn ->
        suffix = Ecto.UUID.generate()

        assert {:ok, %{"commands" => [command]}} =
                 ControlPlane.handle_poll_certificate(worker, poll(worker, "deliver-#{suffix}"))

        assert command["idempotency_key"] == key

        result = %{
          "command_id" => command["command_id"],
          "error" => nil,
          "operation_key" => key,
          "resource" => %{"status" => 200, "body" => body},
          "state" => "succeeded"
        }

        assert {:ok, response} =
                 ControlPlane.handle_poll_certificate(
                   worker,
                   poll(worker, "result-#{suffix}", command_results: [result])
                 )

        assert response["acknowledged_result_command_ids"] == [command["command_id"]]
        :ok
      end
    )
  end

  test "one durable command bridges Work to an authenticated outbound worker exactly once" do
    worker_id = "worker-a"
    certificate_sha256 = digest(worker_id)

    assert {:ok, _worker} =
             CoopWorkers.authorize(worker_id, "workspace-main", certificate_sha256)

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(worker_id, poll(worker_id, "hello"))

    session = session!()
    parent = self()

    task =
      Task.async(fn ->
        receive do
          :start -> :ok
        end

        Bridge.execute(
          session,
          "create_session",
          %{
            "external_ref" => session.external_ref,
            "job" => session.worker_job_document,
            "job_digest" => session.worker_job_digest
          },
          "ryker:work:create:#{session.id}:g1",
          capability_names: ["controller-tools"],
          poll_interval_ms: 1,
          wait: fn ->
            send(parent, :bridge_waiting)

            receive do
              :bridge_continue -> :ok
            end
          end,
          workspace_ref: "workspace-main"
        )
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :start)
    assert_receive :bridge_waiting, 1_000

    assert {:ok, %{"commands" => [command]}} =
             ControlPlane.handle_poll_certificate(worker_id, poll(worker_id, "command"))

    assert command["kind"] == "api_request"
    assert command["command_version"] == 2
    assert command["payload"]["method"] == "POST"
    assert command["payload"]["path"] == "/v1/sessions"
    assert command["payload"]["body"]["task"] == session.external_ref
    refute Map.has_key?(command["payload"]["body"], "policy")

    result = %{
      "command_id" => command["command_id"],
      "error" => nil,
      "operation_key" => command["idempotency_key"],
      "resource" => %{
        "status" => 202,
        "body" => %{"operation" => %{"id" => "operation-1", "state" => "running"}}
      },
      "state" => "succeeded"
    }

    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               worker_id,
               poll(worker_id, "result", command_results: [result])
             )

    assert response["acknowledged_result_command_ids"] == [command["command_id"]]
    send(task.pid, :bridge_continue)

    assert {:ok, %{"operation" => %{"id" => "operation-1"}}} = Task.await(task)
  end

  # The caller read its command's row every 250 ms, two queries a tick, and
  # heard of a result up to a tick late (2026-10-04 review).
  test "a caller waiting on a command hears its result at once, not at its next check" do
    worker_id = "worker-woken"

    assert {:ok, _worker} =
             CoopWorkers.authorize(worker_id, "workspace-main", digest(worker_id))

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(worker_id, poll(worker_id, "hello"))

    session = session!()

    task =
      Task.async(fn ->
        receive do
          :start -> :ok
        end

        Bridge.execute(
          session,
          "create_session",
          %{
            "external_ref" => session.external_ref,
            "job" => session.worker_job_document,
            "job_digest" => session.worker_job_digest
          },
          "ryker:work:create:#{session.id}:g1",
          capability_names: ["controller-tools"],
          max_waits: 1,
          poll_interval_ms: 60_000,
          workspace_ref: "workspace-main"
        )
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :start)
    assert eventually(fn -> Repo.exists?(Command.Query.by_session_id(session.id)) end)

    assert {:ok, %{"commands" => [command]}} =
             ControlPlane.handle_poll_certificate(worker_id, poll(worker_id, "command"))

    result = %{
      "command_id" => command["command_id"],
      "error" => nil,
      "operation_key" => command["idempotency_key"],
      "resource" => %{
        "status" => 202,
        "body" => %{"operation" => %{"id" => "operation-woken", "state" => "running"}}
      },
      "state" => "succeeded"
    }

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               worker_id,
               poll(worker_id, "result", command_results: [result])
             )

    assert {:ok, {:ok, %{"operation" => %{"id" => "operation-woken"}}}} = Task.yield(task, 5_000)
  end

  test "bridge waits preserve typed terminal worker outcomes and bounded retry custody" do
    command = queued_command!()

    assert {:error, {:coop_worker_command_timeout, command_id}} =
             Bridge.await_command(command.id,
               max_waits: 1,
               poll_interval_ms: 1,
               wait: fn -> :ok end,
               workspace_ref: "workspace-main"
             )

    assert command_id == command.id

    assert Bridge.await_command(command.id,
             max_waits: 1,
             poll_interval_ms: 1,
             wait: fn -> {:error, :worker_stopped} end,
             workspace_ref: "workspace-main"
           ) == {:error, :worker_stopped}

    assert Bridge.await_command(command.id,
             max_waits: 1,
             poll_interval_ms: 1,
             wait: fn -> :later end,
             workspace_ref: "workspace-main"
           ) == {:error, {:invalid_coop_worker_bridge_wait, :later}}

    failed =
      command
      |> Ecto.Changeset.change(
        completed_at: Repo.now!(),
        status: :failed,
        error: %{"code" => "revision_conflict", "detail" => "stale", "status" => 409},
        operation_key: command.idempotency_key,
        result_fingerprint: String.duplicate("d", 64)
      )
      |> Repo.update!()

    assert Bridge.await_command(failed.id,
             max_waits: 1,
             poll_interval_ms: 1,
             workspace_ref: "workspace-main"
           ) == {:error, {:coop_error, 409, "revision_conflict", "stale"}}

    uncertain =
      failed
      |> Ecto.Changeset.change(
        status: :uncertain,
        error: %{"detail" => "operation outcome unknown"}
      )
      |> Repo.update!()

    assert Bridge.await_command(uncertain.id,
             max_waits: 1,
             poll_interval_ms: 1,
             workspace_ref: "workspace-main"
           ) == {:error, {:coop_unavailable, "operation outcome unknown"}}

    succeeded =
      uncertain
      |> Ecto.Changeset.change(
        error: nil,
        result: %{"status" => 200, "body" => %{"id" => "remote-result"}},
        status: :succeeded
      )
      |> Repo.update!()

    assert {:ok, %{"id" => "remote-result"}} =
             Bridge.await_command(succeeded.id,
               max_waits: 1,
               poll_interval_ms: 1,
               workspace_ref: "workspace-main"
             )

    Placement
    |> Repo.get!(succeeded.placement_id)
    |> Ecto.Changeset.change(state: :replaced)
    |> Repo.update!()

    # A result settles only while its placement is current, so it still answers
    # once that placement is replaced. A finished answer's checkpoint that had
    # succeeded at 08:19:53 was refused at 15:47 as needing a new session: the
    # worker's identity had expired while the Mac slept and its placements were
    # replaced (2026-10-12, draft PR AndrewDryga/test#24).
    assert {:ok, %{"id" => "remote-result"}} =
             Bridge.await_command(succeeded.id,
               max_waits: 1,
               poll_interval_ms: 1,
               workspace_ref: "workspace-main"
             )

    # A command still in flight on a replaced placement needs a new session.
    in_flight = queued_command!()

    Placement
    |> Repo.get!(in_flight.placement_id)
    |> Ecto.Changeset.change(state: :replaced)
    |> Repo.update!()

    assert {:error, {:coop_session_replacement_required, session_id, placement_generation}} =
             Bridge.await_command(in_flight.id,
               max_waits: 1,
               poll_interval_ms: 1,
               workspace_ref: "workspace-main"
             )

    assert session_id == in_flight.session_id
    assert placement_generation == in_flight.placement_generation

    assert {:error, {:coop_worker_command_not_found, missing_id}} =
             Bridge.await_command(Ecto.UUID.generate(),
               max_waits: 1,
               poll_interval_ms: 1,
               workspace_ref: "workspace-main"
             )

    assert is_binary(missing_id)
  end

  # The read found a command settled before its settle message was taken, and
  # the message stayed in the caller's mailbox. A GenServer that waited got it
  # later as "[error] Ryker.Retention.Worker received an unexpected message:
  # {:coop_command_settled, …}" (live, 2026-10-09 19:53 UTC).
  test "a wait leaves no settle message behind in its caller's mailbox" do
    command = queued_command!()

    settle = fn ->
      command
      |> Ecto.Changeset.change(
        completed_at: Repo.now!(),
        result: %{"status" => 200, "body" => %{"id" => "remote-result"}},
        status: :succeeded
      )
      |> Repo.update!()

      send(self(), {:coop_command_settled, command.id})
      :ok
    end

    assert {:ok, %{"id" => "remote-result"}} =
             Bridge.await_command(command.id,
               max_waits: 2,
               poll_interval_ms: 1,
               wait: settle,
               workspace_ref: "workspace-main"
             )

    refute_received {:coop_command_settled, _command_id}
  end

  test "transport success does not turn an API refusal into business success" do
    command = queued_command!()

    command
    |> Ecto.Changeset.change(
      completed_at: Repo.now!(),
      status: :succeeded,
      operation_key: command.idempotency_key,
      result_fingerprint: String.duplicate("e", 64),
      result: %{
        "status" => 409,
        "body" => %{"error" => %{"code" => "revision_conflict", "detail" => "stale"}}
      }
    )
    |> Repo.update!()

    assert Bridge.await_command(command.id, max_waits: 1, workspace_ref: "workspace-main") ==
             {:error, {:coop_error, 409, "revision_conflict", "stale"}}

    assert Bridge.response(%{"status" => 200, "body" => [1, 2]}) == {:ok, [1, 2]}
    assert Bridge.response(%{"status" => 204}) == {:ok, nil}
    assert Bridge.response(%{"id" => "old"}) == {:error, {:invalid_coop_worker_bridge, :response}}
  end

  test "stored response bodies resolve as JSON or a binary file without losing their identity" do
    key = Ryker.Secret.new(:binary.copy(<<7>>, 32))
    command = queued_command!()
    root = Path.join(System.tmp_dir!(), "coop-bridge-bodies-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)

    for {id, type, bytes} <- [
          {command.id, "application/json",
           Jason.encode!(%{"large" => String.duplicate("j", 300 * 1_024)})},
          {Ecto.UUID.generate(), "application/octet-stream", <<0, 255, 1, 2>>}
        ] do
      reference = %{
        "byte_size" => byte_size(bytes),
        "sha256" => digest(bytes)
      }

      assert Bodies.put(root, id, :response, reference, [bytes], key) == :ok

      response = %{
        command
        | id: id,
          result: %{
            "status" => 200,
            "headers" => %{"Content-Type" => type},
            "body_ref" => reference
          }
      }

      if type == "application/json" do
        assert {:ok, body} = Bridge.command_response(response, root, key)
        assert body == Jason.decode!(bytes)
      else
        assert {:ok, %{stored_body: body, body_ref: ^reference}} =
                 Bridge.command_response(response, root, key)

        assert {:ok, ^bytes} = Bodies.read(body, key, byte_size(bytes))
      end

      assert {:error, _} = Bridge.command_response(response, Path.join(root, "unavailable"), key)
    end
  end

  test "bridge options and session identities fail closed before placement" do
    assert Bridge.execute(%{}, "get_session", %{}, "key", []) ==
             {:error, {:invalid_coop_worker_bridge, :session}}

    for invalid <- [
          nil,
          [workspace_ref: "workspace-main", workspace_ref: "duplicate"],
          [workspace_ref: "workspace-main", secret: "must-not-cross"],
          [workspace_ref: "workspace-main", capability_names: :all],
          [workspace_ref: "workspace-main", capability_versions: :all],
          [workspace_ref: "workspace-main", capability_versions: %{"freshness" => ""}],
          [workspace_ref: "workspace-main", max_waits: 0],
          [workspace_ref: "workspace-main", lease_seconds: 0],
          [workspace_ref: "workspace-main", poll_interval_ms: 0]
        ] do
      assert Bridge.await_command(Ecto.UUID.generate(), invalid) ==
               {:error, {:invalid_coop_worker_bridge, :options}}
    end
  end

  defp session! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "fleet:bridge:#{episode_id}",
                 native_input_id: "source:bridge:#{episode_id}",
                 occurred_at: Repo.now!(),
                 turn_ref: "turn:bridge:#{episode_id}"
               })
             )

    assert {:ok, session} =
             WorkSessions.pin_episode(episode_id, "work-read-only", @policy_digest,
               repository_ref: "ryker"
             )

    WorkerJob.pin!(session)
  end

  defp queued_command! do
    worker_id = "bridge-worker-#{Ecto.UUID.generate()}"
    certificate_sha256 = digest(worker_id)

    assert {:ok, _worker} =
             CoopWorkers.authorize(worker_id, "workspace-main", certificate_sha256)

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(worker_id, poll(worker_id, "ready"))

    session = session!()

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: session.repository_ref,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "create_session",
               %{"external_ref" => session.external_ref},
               "bridge:test:#{Ecto.UUID.generate()}"
             )

    command
  end

  defp poll(worker_id, suffix, options \\ []) do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => Keyword.get(options, :command_results, []),
      "event_batches" => [],
      "poll_ref" => "poll:#{worker_id}:#{suffix}",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-test",
        "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
        "capacity" => %{
          "cooldown_until" => nil,
          "session_slots_free" => 2,
          "session_slots_total" => 2,
          "state" => "eligible",
          "turn_slots_free" => 2,
          "turn_slots_total" => 2,
          "workspace_slots_free" => 2,
          "workspace_slots_total" => 2
        },
        "clock_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "id" => worker_id,
        "protocol_version" => "2",
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end
end
