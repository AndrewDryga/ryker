defmodule Ryker.CoopFleet.BridgeTest do
  use Ryker.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CoopFleet.{Bridge, ControlPlane, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.Work.Custody

  @policy_digest String.duplicate("b", 64)

  test "one durable command bridges Work to an authenticated outbound worker exactly once" do
    worker_id = "worker-a"
    certificate_sha256 = :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower)

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(worker_id, "workspace-main", certificate_sha256)

    assert {:ok, _response} = ControlPlane.handle_poll(worker_id, poll(worker_id, "hello"))
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
            "policy" => session.policy,
            "policy_digest" => session.policy_digest
          },
          "ryker:work:create:#{session.id}:g1",
          capability_names: ["responder-state"],
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
             ControlPlane.handle_poll(worker_id, poll(worker_id, "command"))

    result = %{
      "command_id" => command["command_id"],
      "error" => nil,
      "operation_key" => command["idempotency_key"],
      "resource" => %{"operation" => %{"id" => "operation-1", "state" => "running"}},
      "state" => "succeeded"
    }

    assert {:ok, response} =
             ControlPlane.handle_poll(
               worker_id,
               poll(worker_id, "result", command_results: [result])
             )

    assert response["acknowledged_result_command_ids"] == [command["command_id"]]
    send(task.pid, :bridge_continue)

    assert {:ok, %{"operation" => %{"id" => "operation-1"}}} = Task.await(task)
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

    assert {:error, :worker_stopped} =
             Bridge.await_command(command.id,
               max_waits: 1,
               poll_interval_ms: 1,
               wait: fn -> {:error, :worker_stopped} end,
               workspace_ref: "workspace-main"
             )

    assert {:error, {:invalid_coop_worker_bridge_wait, :later}} =
             Bridge.await_command(command.id,
               max_waits: 1,
               poll_interval_ms: 1,
               wait: fn -> :later end,
               workspace_ref: "workspace-main"
             )

    failed =
      command
      |> Ecto.Changeset.change(
        completed_at: database_now!(),
        status: :failed,
        error: %{"code" => "revision_conflict", "detail" => "stale", "status" => 409},
        operation_key: command.idempotency_key,
        result_fingerprint: String.duplicate("d", 64)
      )
      |> Repo.update!()

    assert {:error, {:coop_error, 409, "revision_conflict", "stale"}} =
             Bridge.await_command(failed.id,
               max_waits: 1,
               poll_interval_ms: 1,
               workspace_ref: "workspace-main"
             )

    uncertain =
      failed
      |> Ecto.Changeset.change(
        status: :uncertain,
        error: %{"detail" => "operation outcome unknown"}
      )
      |> Repo.update!()

    assert {:error, {:coop_unavailable, "operation outcome unknown"}} =
             Bridge.await_command(uncertain.id,
               max_waits: 1,
               poll_interval_ms: 1,
               workspace_ref: "workspace-main"
             )

    succeeded =
      uncertain
      |> Ecto.Changeset.change(
        error: nil,
        result: %{"id" => "remote-result"},
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

    assert {:error, {:coop_session_replacement_required, session_id, placement_generation}} =
             Bridge.await_command(succeeded.id,
               max_waits: 1,
               poll_interval_ms: 1,
               workspace_ref: "workspace-main"
             )

    assert session_id == succeeded.session_id
    assert placement_generation == succeeded.placement_generation

    assert {:error, {:coop_worker_command_not_found, missing_id}} =
             Bridge.await_command(Ecto.UUID.generate(),
               max_waits: 1,
               poll_interval_ms: 1,
               workspace_ref: "workspace-main"
             )

    assert is_binary(missing_id)
  end

  test "bridge options and session identities fail closed before placement" do
    assert {:error, {:invalid_coop_worker_bridge, :session}} =
             Bridge.execute(%{}, "get_session", %{}, "key", [])

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
      assert {:error, {:invalid_coop_worker_bridge, :options}} =
               Bridge.await_command(Ecto.UUID.generate(), invalid)
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
                 occurred_at: database_now!(),
                 turn_ref: "turn:bridge:#{episode_id}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(episode_id, "work-read-only", @policy_digest, "ryker")

    session
  end

  defp queued_command! do
    worker_id = "bridge-worker-#{Ecto.UUID.generate()}"
    certificate_sha256 = :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower)

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(worker_id, "workspace-main", certificate_sha256)

    assert {:ok, _response} = ControlPlane.handle_poll(worker_id, poll(worker_id, "ready"))
    session = session!()

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
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
      "version" => 1,
      "worker" => %{
        "build_version" => "coop-test",
        "capabilities" => [%{"name" => "responder-state", "version" => "1"}],
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
        "policy_digests" => %{"work-read-only" => @policy_digest},
        "protocol_version" => "1",
        "repositories" => [%{"ref" => "ryker", "revision" => "commit:abc123"}],
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end

  defp database_now! do
    %{rows: [[now]]} = Ryker.Repo.query!("SELECT clock_timestamp()")
    now
  end
end
