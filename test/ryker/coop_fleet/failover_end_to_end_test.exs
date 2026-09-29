defmodule Ryker.CoopFleet.FailoverEndToEndTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  alias Ryker.CoopFleet.{
    Bodies,
    Checkpoints,
    Client,
    Command,
    ControlPlane,
    JobSpec,
    Placement,
    Worker,
    WorkspaceCheckpointTransfer
  }

  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkspaceCheckpoint, as: WorkspaceCheckpointFixture
  alias Ryker.Repo
  alias Ryker.Work.{Custody, SessionChangeset}

  @policy "work-read-only"
  @policy_digest String.duplicate("b", 64)
  @checkpoint_key :binary.copy(<<7>>, 32)
  @worker_a "failover-worker-a"
  @worker_b "failover-worker-b"

  test "writable work restores its exact encrypted checkpoint on a second fenced worker" do
    worker_a = authorize_and_poll!(@worker_a, 2)
    worker_b = authorize_and_poll!(@worker_b, 1)
    {claim, source} = writable_claim!()

    assert {:ok, source_placement} = place(source)
    assert source_placement.worker_id == worker_a.id

    assert {:ok, checkpoint_command} =
             ControlPlane.enqueue_command(
               source_placement.id,
               "checkpoint_workspace",
               %{
                 "coop_session_id" => source.coop_session_id,
                 "expected_revision" => 4,
                 "repository_ref" => source.repository_ref,
                 "session_ref" => source.id
               },
               "ryker:e2e:checkpoint:#{source.id}"
             )

    assert {:ok, %{"commands" => [checkpoint_wire]}} =
             ControlPlane.handle_poll_certificate(
               worker_a.certificate,
               poll(worker_a.id, "checkpoint")
             )

    assert checkpoint_wire["command_id"] == checkpoint_command.id
    assert checkpoint_wire["placement_generation"] == source_placement.generation

    {checkpoint, bundle} =
      WorkspaceCheckpointFixture.build(%{
        session_ref: source.id,
        placement_generation: source_placement.generation
      })

    root = Path.join(System.tmp_dir!(), "failover-bodies-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)

    descriptor = %{
      "checkpoint" => checkpoint,
      "operation" => %{
        "id" => "op-checkpoint",
        "method" => "CheckpointWorkspace",
        "state" => "succeeded"
      }
    }

    assert {:ok, _} =
             ControlPlane.handle_poll_certificate(
               worker_a.certificate,
               poll(worker_a.id, "checkpoint-result",
                 command_results: [result(checkpoint_wire, descriptor)]
               )
             )

    capture_options = [
      body_root: root,
      checkpoint_key: @checkpoint_key,
      checkpoint_secrets: [],
      workspace_ref: "workspace-main",
      max_waits: 3,
      poll_interval_ms: 1,
      wait: fn ->
        assert {:ok, %{"commands" => [get]}} =
                 ControlPlane.handle_poll_certificate(
                   worker_a.certificate,
                   poll(worker_a.id, "get-bundle")
                 )

        assert get["payload"]["path"] == "/v1/operations/op-checkpoint/checkpoint-bundle"
        reference = Map.take(checkpoint["bundle"], ~w(sha256 byte_size))

        assert :ok =
                 Bodies.put(
                   root,
                   get["command_id"],
                   :response,
                   reference,
                   [bundle],
                   @checkpoint_key
                 )

        response =
          result(get, nil)
          |> Map.put("resource", %{
            "status" => 200,
            "body_ref" => reference,
            "headers" => %{
              "Content-Type" => checkpoint["bundle"]["media_type"],
              "Etag" => ~s("#{reference["sha256"]}")
            }
          })

        assert {:ok, _} =
                 ControlPlane.handle_poll_certificate(
                   worker_a.certificate,
                   poll(worker_a.id, "bundle-result", command_results: [response]),
                   body_root: root
                 )

        :ok
      end
    ]

    assert {:ok, receipt} =
             Checkpoints.capture(
               source.id,
               checkpoint_command.idempotency_key,
               descriptor,
               capture_options
             )

    transfer = Repo.get!(WorkspaceCheckpointTransfer, receipt["transfer_id"])
    assert transfer.body_command_id != nil
    assert transfer.ciphertext == nil

    expire_and_drain!(source_placement, worker_a.id)

    assert {:error, {:coop_session_replacement_required, source_id, generation}} =
             place(source)

    assert source_id == source.id
    assert generation == source_placement.generation
    assert Repo.get!(Placement, source_placement.id).state == :replaced

    assert {:ok, rotated} =
             Custody.replace_session_after_placement_loss(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               source.generation
             )

    assert rotated.session.generation == source.generation + 1
    assert rotated.session.worker_job_document["job_ref"] == rotated.session.external_ref

    assert Map.delete(rotated.session.worker_job_document, "job_ref") ==
             Map.delete(source.worker_job_document, "job_ref")

    assert {:ok, rotated_digest} = JobSpec.digest(rotated.session.worker_job_document)
    assert rotated.session.worker_job_digest == rotated_digest
    assert rotated.session.workspace_task == source.workspace_task
    assert is_nil(rotated.session.coop_session_id)

    assert {:ok, client} =
             Client.new(
               body_root: root,
               checkpoint_key: @checkpoint_key,
               checkpoint_secrets: [],
               capability_names: ["controller-tools"],
               lease_seconds: 60,
               max_waits: 4,
               poll_interval_ms: 1,
               wait: bridge_wait(self()),
               workspace_ref: "workspace-main"
             )

    create_key = "ryker:work:create:#{rotated.session.id}:g1"

    task =
      Task.async(fn ->
        receive do
          :start ->
            Client.create_session(
              client,
              create_key,
              rotated.session.policy,
              rotated.session.external_ref,
              rotated.session.repository_source
            )
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :start)

    # The bridge took more than a second under the full gate (dev-check,
    # 2026-09-29); a wait of five holds nothing up when it is prompt.
    assert_receive {:bridge_waiting, first_waiter}, 5_000

    assert {:ok, %{"commands" => [create_wire]}} =
             ControlPlane.handle_poll_certificate(
               worker_b.certificate,
               poll(worker_b.id, "create")
             )

    assert create_wire["kind"] == "api_request"
    assert create_wire["payload"]["path"] == "/v1/sessions"
    assert create_wire["placement_generation"] == 1
    assert create_wire["worker_id"] == worker_b.id

    assert {:ok, create_result} =
             ControlPlane.handle_poll_certificate(
               worker_b.certificate,
               poll(worker_b.id, "create-result",
                 command_results: [
                   result(create_wire, %{
                     "session" => %{
                       "id" => "coop-session-worker-b",
                       "revision" => 1,
                       "state" => "open"
                     }
                   })
                 ]
               )
             )

    assert create_result["acknowledged_result_command_ids"] == [create_wire["command_id"]]
    send(first_waiter, :bridge_continue)

    assert_receive {:bridge_waiting, second_waiter}, 5_000

    assert {:ok, %{"commands" => [restore_wire]}} =
             ControlPlane.handle_poll_certificate(
               worker_b.certificate,
               poll(worker_b.id, "restore"),
               body_root: root,
               checkpoint_key: @checkpoint_key
             )

    assert restore_wire["kind"] == "api_request"

    assert restore_wire["payload"]["path"] ==
             "/v1/sessions/coop-session-worker-b/workspace/restore"

    assert restore_wire["payload"]["body_ref"] ==
             Map.take(checkpoint["bundle"], ~w(sha256 byte_size))

    assert {:error, :body_not_authorized} =
             Bodies.authorize(worker_a.certificate, restore_wire["command_id"])

    assert {:ok, _} = Bodies.authorize(worker_b.certificate, restore_wire["command_id"])
    assert {:ok, body, _} = Bodies.fetch(root, restore_wire["command_id"], :request)
    assert {:ok, ^bundle} = Bodies.read(body, @checkpoint_key, byte_size(bundle))

    assert {:ok, restore_result} =
             ControlPlane.handle_poll_certificate(
               worker_b.certificate,
               poll(worker_b.id, "restore-result",
                 command_results: [
                   result(restore_wire, %{
                     "session" => %{
                       "id" => "coop-session-worker-b",
                       "revision" => 2,
                       "state" => "open"
                     }
                   })
                 ]
               )
             )

    assert restore_result["acknowledged_result_command_ids"] == [restore_wire["command_id"]]
    send(second_waiter, :bridge_continue)

    assert {:ok, remote} = Task.await(task)

    assert remote == %{
             "session" => %{"id" => "coop-session-worker-b", "revision" => 2, "state" => "open"}
           }

    assert Repo.get!(Placement, source_placement.id).state == :replaced

    assert Repo.get!(Placement, restore_wire["command_id"] |> command_placement_id()).worker_id ==
             worker_b.id
  end

  defp writable_claim! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "fleet:failover:#{episode_id}",
                 native_input_id: "source:failover:#{episode_id}",
                 occurred_at: Repo.now!(),
                 turn_ref: "turn:failover:#{episode_id}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(episode_id, @policy, @policy_digest, "ryker")

    job = WorkerJob.build(session.external_ref, "ryker")
    assert {:ok, job_digest} = JobSpec.digest(job)

    session =
      session
      |> Ecto.Changeset.change(worker_job_document: job, worker_job_digest: job_digest)
      |> Repo.update!()

    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "instruction_ref" => "input:failover:1",
      "offer_ref" => "record:task_offer:failover",
      "prompt" => "Continue the exact reviewed workspace after worker loss.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Prove checkpoint failover"
    }

    source =
      session
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Ecto.Changeset.change(coop_session_id: "coop-session-worker-a")
      |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("ryker-worker-a", 60, :work)
    assert claim.session.id == source.id
    {%{claim | session: source}, source}
  end

  defp authorize_and_poll!(worker_id, free_slots) do
    certificate = "certificate:#{worker_id}:#{Ecto.UUID.generate()}"
    fingerprint = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(worker_id, "workspace-main", fingerprint)

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               certificate,
               poll(worker_id, "hello", free_slots: free_slots)
             )

    %{certificate: certificate, id: worker_id}
  end

  defp place(session) do
    ControlPlane.place_session(
      session.id,
      %{
        capability_names: ["controller-tools"],
        repository_ref: session.repository_ref,
        workspace_ref: "workspace-main"
      },
      60
    )
  end

  defp expire_and_drain!(placement, worker_id) do
    now = Repo.now!()

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(now, -1, :second)]
    )

    Repo.update_all(
      from(value in Worker, where: value.id == ^worker_id),
      set: [drain_requested_at: now, state: :draining]
    )
  end

  defp bridge_wait(parent) do
    fn ->
      send(parent, {:bridge_waiting, self()})

      receive do
        :bridge_continue -> :ok
      end
    end
  end

  defp result(command, resource) do
    %{
      "command_id" => command["command_id"],
      "error" => nil,
      "operation_key" => command["idempotency_key"],
      "resource" => %{"status" => 200, "body" => resource},
      "state" => "succeeded"
    }
  end

  defp command_placement_id(command_id) do
    Command |> Repo.get!(command_id) |> Map.fetch!(:placement_id)
  end

  defp poll(worker_id, suffix, options \\ []) do
    free_slots = Keyword.get(options, :free_slots, 1)

    %{
      "acknowledged_command_ids" => Keyword.get(options, :acknowledged_command_ids, []),
      "command_results" => Keyword.get(options, :command_results, []),
      "event_batches" => [],
      "poll_ref" => "poll:#{worker_id}:#{suffix}",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-e2e",
        "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
        "capacity" => %{
          "cooldown_until" => nil,
          "session_slots_free" => free_slots,
          "session_slots_total" => 2,
          "state" => "eligible",
          "turn_slots_free" => free_slots,
          "turn_slots_total" => 2,
          "workspace_slots_free" => free_slots,
          "workspace_slots_total" => 2
        },
        "clock_at" => DateTime.to_iso8601(Repo.now!()),
        "id" => worker_id,
        "protocol_version" => "2",
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end
end
