defmodule Ryker.CoopFleet.PlacementConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CoopFleet.{Certificate, Client, Command, ControlPlane, JobSpec, Placement, Worker}
  alias Ryker.CoopFleet.ControlPlane.Commands
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Repo
  alias Ryker.Work.{Custody, Session, SessionChangeset}

  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  test "cancellation during source preparation prevents a late creator consuming capacity" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace = "workspace-fence-#{suffix}"
      worker = "worker-fence-#{suffix}"
      session = session!("fence-#{suffix}")
      key = "create:fence-#{suffix}"
      parent = self()
      authorize_and_poll!(worker, workspace)
      {:ok, client} = Client.new(workspace_ref: workspace)

      creator =
        unboxed_task(fn ->
          # The creator is already resolving code, outside any DB transaction.
          # Resume at the actual post-resolution job pin and outbound create seam.
          send(parent, :preparing_source)

          receive do
            :source_ready -> :ok
          end

          prepared = pin_job!(session)

          Client.create_session(
            client,
            key,
            prepared.policy,
            prepared.external_ref,
            prepared.repository_source
          )
        end)

      try do
        assert_receive :preparing_source, 5_000

        assert {:ok, %{"error_code" => "operation_not_enqueued"}} =
                 Client.fence_create_session(
                   client,
                   key,
                   session.policy,
                   session.external_ref,
                   session.repository_source
                 )

        send(creator.pid, :source_ready)

        assert {:error, {:coop_error, 409, "operation_not_enqueued", _}} =
                 Task.await(creator, 5_000)

        assert Repo.aggregate(from(p in Placement, where: p.session_id == ^session.id), :count) ==
                 0

        assert %Command{status: :failed, placement_id: nil} =
                 Repo.get_by!(Command, idempotency_key: key)
      after
        send(creator.pid, :source_ready)
        stop_tasks([creator])
        cleanup!([session], [worker])
      end
    end)
  end

  test "a fence waits for an enqueue winner and returns its exact command" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace = "workspace-enqueue-#{suffix}"
      worker = "worker-enqueue-#{suffix}"
      session = session!("enqueue-#{suffix}") |> pin_job!()
      key = "create:enqueue-#{suffix}"
      parent = self()
      authorize_and_poll!(worker, workspace)

      {:ok, placement} =
        ControlPlane.place_session(
          session.id,
          %{
            workspace_ref: workspace,
            repository_ref: "ryker",
            capability_names: ["controller-tools"]
          },
          60
        )

      payload = %{
        "external_ref" => session.external_ref,
        "job" => session.worker_job_document,
        "job_digest" => session.worker_job_digest
      }

      creator =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            {:ok, command} =
              ControlPlane.enqueue_command(placement.id, "create_session", payload, key)

            send(parent, {:enqueued, backend_pid(), command})

            receive do
              :commit -> command
            end
          end)
        end)

      try do
        assert_receive {:enqueued, creator_backend, command}, 5_000

        fencer =
          unboxed_task(fn ->
            send(parent, {:fencer, backend_pid()})

            ControlPlane.fence_command(
              session,
              "create_session",
              Commands.create_intent(session, session.external_ref),
              key
            )
          end)

        try do
          assert_receive {:fencer, fencer_backend}, 5_000
          await_blocked_by(fencer_backend, creator_backend)
          send(creator.pid, :commit)
          assert {:ok, ^command} = Task.await(creator, 5_000)
          assert {:ok, ^command} = Task.await(fencer, 5_000)
          assert command.status == :queued
        after
          send(creator.pid, :commit)
          stop_tasks([fencer])
        end
      after
        send(creator.pid, :commit)
        stop_tasks([creator])
        cleanup!([session], [worker])
      end
    end)
  end

  test "one placement locks only the worker it selects" do
    # The fleet can receive several placements at once. Locking every eligible
    # worker for one choice made idle capacity look unavailable to the others.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace_ref = "workspace-placement-#{suffix}"
      worker_ids = ["worker-a-#{suffix}", "worker-b-#{suffix}"]

      sessions =
        Enum.map([session!("first-#{suffix}"), session!("second-#{suffix}")], &pin_job!/1)

      parent = self()

      Enum.each(worker_ids, &authorize_and_poll!(&1, workspace_ref))

      requirements = %{
        capability_names: ["controller-tools"],
        repository_ref: "ryker",
        workspace_ref: workspace_ref
      }

      try do
        holder =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              result = ControlPlane.place_session(Enum.at(sessions, 0).id, requirements, 60)
              send(parent, {:first_placement, result})

              receive do
                :release -> :ok
              end
            end)
          end)

        Process.put({__MODULE__, :holder}, holder)
        assert_receive {:first_placement, {:ok, first}}, 5_000

        contender =
          unboxed_task(fn ->
            ControlPlane.place_session(Enum.at(sessions, 1).id, requirements, 60)
          end)

        Process.put({__MODULE__, :contender}, contender)

        assert {:ok, second} = Task.await(contender, 5_000)
        assert second.worker_id != first.worker_id

        send(holder.pid, :release)
        assert {:ok, _transaction} = Task.await(holder, 5_000)
      after
        tasks =
          [
            Process.delete({__MODULE__, :holder}),
            Process.delete({__MODULE__, :contender})
          ]
          |> Enum.reject(&is_nil/1)

        Enum.each(tasks, &send(&1.pid, :release))
        stop_tasks(tasks)
        cleanup!(sessions, worker_ids)
      end
    end)
  end

  test "a committed placement reserves capacity across heartbeats before execution" do
    # Placement and command delivery are separate transactions. Without a durable
    # reservation, several sessions could consume the same last heartbeat slot
    # before the worker had a chance to report reduced capacity.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace_ref = "workspace-reservation-#{suffix}"
      worker_id = "worker-reservation-#{suffix}"

      sessions =
        Enum.map(
          [session!("reserved-first-#{suffix}"), session!("reserved-second-#{suffix}")],
          &pin_job!/1
        )

      authorize_and_poll!(worker_id, workspace_ref)

      requirements = %{
        capability_names: ["controller-tools"],
        repository_ref: "ryker",
        workspace_ref: workspace_ref
      }

      try do
        assert {:ok, first} =
                 ControlPlane.place_session(Enum.at(sessions, 0).id, requirements, 60)

        assert first.worker_id == worker_id

        # The worker has not executed create yet, so it still reports its slot free.
        # A newer heartbeat must not erase the controller's durable reservation.
        poll_worker!(worker_id, workspace_ref)

        assert ControlPlane.place_session(Enum.at(sessions, 1).id, requirements, 60) ==
                 {:error, {:coop_worker_capacity_unavailable, Enum.at(sessions, 1).id}}

        assert Repo.aggregate(
                 from(placement in Placement,
                   where:
                     placement.worker_id == ^worker_id and
                       placement.state in [:assigning, :active, :draining, :revoking]
                 ),
                 :count
               ) == 1
      after
        cleanup!(sessions, [worker_id])
      end
    end)
  end

  test "activity custody does not block session placement" do
    # A routine follow-up deadlocked after Coop activity held the placement and its Session FK.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace_ref = "workspace-activity-#{suffix}"
      worker_id = "worker-activity-#{suffix}"
      session = session!("activity-#{suffix}") |> pin_job!()
      parent = self()

      authorize_and_poll!(worker_id, workspace_ref)

      holder =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(value in Session,
                where: value.id == ^session.id,
                lock: "FOR KEY SHARE"
              )
            )

            send(parent, :activity_session_reference_held)

            receive do
              :release_activity -> :ok
            end
          end)
        end)

      try do
        assert_receive :activity_session_reference_held, 5_000

        contender =
          unboxed_task(fn ->
            ControlPlane.place_session(
              session.id,
              %{
                capability_names: ["controller-tools"],
                repository_ref: "ryker",
                workspace_ref: workspace_ref
              },
              60
            )
          end)

        Process.put({__MODULE__, :activity_contender}, contender)
        placement_result = Task.yield(contender, 5_000)
        send(holder.pid, :release_activity)
        assert {:ok, _transaction} = Task.await(holder, 5_000)

        if placement_result == nil do
          assert {:ok, _placement} = Task.await(contender, 5_000)
          flunk("session placement waited on activity's foreign-key reference")
        end

        assert {:ok, {:ok, placement}} = placement_result
        assert placement.session_id == session.id
      after
        send(holder.pid, :release_activity)

        [holder, Process.delete({__MODULE__, :activity_contender})]
        |> Enum.reject(&is_nil/1)
        |> stop_tasks()

        cleanup!([session], [worker_id])
      end
    end)
  end

  # A poll holds its worker's row while it runs, and placement skipped any
  # worker locked that way: a task that arrived during a poll found no worker
  # at all and stopped for a person (2026-10-04 review).
  test "a placement that arrives during a poll waits for it instead of finding no worker" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace = "workspace-poll-race-#{suffix}"
      worker = "worker-poll-race-#{suffix}"
      session = session!("poll-race-#{suffix}") |> pin_job!()
      authorize_and_poll!(worker, workspace)
      poller = hold_worker(worker)
      assert_receive {:holding, poll_backend}, 5_000
      placer = place(session, workspace)

      try do
        assert_receive {:placing, place_backend}, 5_000
        await_blocked_by(place_backend, poll_backend)
        send(poller.pid, :release)

        assert {:ok, %Placement{worker_id: ^worker}} = Task.await(placer, 5_000)
      after
        finish!([poller, placer])
        cleanup!([session], [worker])
      end
    end)
  end

  # Recovery locked a session's placement and then its worker, while a poll
  # locks the worker and then its placements: each could wait for the other
  # (2026-10-04 review). Recovery now waits for the worker before it touches
  # the placement.
  test "recovering a placement waits for its worker before it locks the placement" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace = "workspace-lock-order-#{suffix}"
      worker = "worker-lock-order-#{suffix}"
      session = session!("lock-order-#{suffix}") |> pin_job!()
      authorize_and_poll!(worker, workspace)

      {:ok, placement} =
        ControlPlane.place_session(
          session.id,
          %{
            workspace_ref: workspace,
            repository_ref: "ryker",
            capability_names: ["controller-tools"]
          },
          60
        )

      Repo.update_all(from(s in Session, where: s.id == ^session.id),
        set: [coop_session_id: "coop-lock-order-#{suffix}"]
      )

      Repo.update_all(from(p in Placement, where: p.id == ^placement.id), set: [state: :replaced])
      poller = hold_worker(worker)
      assert_receive {:holding, poll_backend}, 5_000
      placer = place(session, workspace)

      try do
        assert_receive {:placing, place_backend}, 5_000
        await_blocked_by(place_backend, poll_backend)

        # The poll could take the placement now and finish.
        assert {:ok, _locked} =
                 Repo.transaction(fn ->
                   Repo.query!(
                     "SELECT 1 FROM coop_session_placements WHERE id = $1 FOR UPDATE NOWAIT",
                     [Ecto.UUID.dump!(placement.id)]
                   )
                 end)

        send(poller.pid, :release)
        Task.await(placer, 5_000)
      after
        finish!([poller, placer])
        cleanup!([session], [worker])
      end
    end)
  end

  # Releases the held worker and lets the placement finish before the rows go.
  defp finish!([poller | _rest] = tasks) do
    send(poller.pid, :release)
    Enum.each(tasks, &Task.yield(&1, 5_000))
    stop_tasks(tasks)
  end

  # A poll's hold on its worker row, until told to finish.
  defp hold_worker(worker_id) do
    parent = self()

    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT 1 FROM coop_workers WHERE id = $1 FOR UPDATE", [worker_id])
        send(parent, {:holding, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp place(session, workspace) do
    parent = self()

    unboxed_task(fn ->
      send(parent, {:placing, backend_pid()})

      ControlPlane.place_session(
        session.id,
        %{
          workspace_ref: workspace,
          repository_ref: "ryker",
          capability_names: ["controller-tools"]
        },
        60
      )
    end)
  end

  defp authorize_and_poll!(worker_id, workspace_ref) do
    certificate = "certificate-#{worker_id}"
    digest = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    assert {:ok, _worker} = ControlPlane.authorize_worker(worker_id, workspace_ref, digest)

    poll_worker!(worker_id, workspace_ref)
  end

  defp poll_worker!(worker_id, workspace_ref) do
    assert {:ok, _response} =
             ControlPlane.handle_poll(worker_id, %{
               "acknowledged_command_ids" => [],
               "command_results" => [],
               "event_batches" => [],
               "poll_ref" => "poll:#{worker_id}:#{Ecto.UUID.generate()}",
               "version" => 2,
               "worker" => %{
                 "build_version" => "coop-test",
                 "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
                 "capacity" => %{
                   "cooldown_until" => nil,
                   "session_slots_free" => 1,
                   "session_slots_total" => 1,
                   "state" => "eligible",
                   "turn_slots_free" => 1,
                   "turn_slots_total" => 1,
                   "workspace_slots_free" => 1,
                   "workspace_slots_total" => 1
                 },
                 "clock_at" => DateTime.to_iso8601(Repo.now!()),
                 "id" => worker_id,
                 "protocol_version" => "2",
                 "sandbox_digest" => @sandbox_digest,
                 "state" => "eligible",
                 "workspace_ref" => workspace_ref
               }
             })
  end

  defp session!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "fleet-placement:#{suffix}",
        native_input_id: "source:#{suffix}",
        occurred_at: Repo.now!(),
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               @policy_digest,
               "ryker"
             )

    session
  end

  defp pin_job!(session) do
    job = WorkerJob.build(session.external_ref, session.repository_ref)
    {:ok, digest} = JobSpec.digest(job)
    session |> SessionChangeset.pin_worker_job(job, digest) |> Repo.update!()
  end

  defp cleanup!(sessions, worker_ids) do
    session_ids = Enum.map(sessions, & &1.id)
    episode_ids = Enum.map(sessions, & &1.episode_id)

    Repo.delete_all(from(command in Command, where: command.session_id in ^session_ids))
    Repo.delete_all(from(placement in Placement, where: placement.session_id in ^session_ids))
    Repo.delete_all(from(session in Session, where: session.id in ^session_ids))
    Repo.delete_all(from(event in Event, where: event.episode_id in ^episode_ids))
    Repo.delete_all(from(episode in Episode, where: episode.id in ^episode_ids))
    Repo.delete_all(from(certificate in Certificate, where: certificate.worker_id in ^worker_ids))
    Repo.delete_all(from(worker in Worker, where: worker.id in ^worker_ids))
  end
end
