defmodule Responder.CoopFleet.PlacementConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.CoopFleet.{Certificate, ControlPlane, Placement, Worker}
  alias Responder.Episodes
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.{Custody, Session}

  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  test "one placement locks only the worker it selects" do
    # The fleet can receive several placements at once. Locking every eligible
    # worker for one choice made idle capacity look unavailable to the others.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace_ref = "workspace-placement-#{suffix}"
      worker_ids = ["worker-a-#{suffix}", "worker-b-#{suffix}"]
      sessions = [session!("first-#{suffix}"), session!("second-#{suffix}")]
      parent = self()

      Enum.each(worker_ids, &authorize_and_poll!(&1, workspace_ref))

      requirements = %{
        capability_names: ["responder-state"],
        repository_ref: "responder",
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

  test "a committed placement reserves the worker's last reported slot" do
    # Placement and command delivery are separate transactions. Without a durable
    # reservation, several sessions could consume the same last heartbeat slot
    # before the worker had a chance to report reduced capacity.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      workspace_ref = "workspace-reservation-#{suffix}"
      worker_id = "worker-reservation-#{suffix}"
      sessions = [session!("reserved-first-#{suffix}"), session!("reserved-second-#{suffix}")]

      authorize_and_poll!(worker_id, workspace_ref)

      requirements = %{
        capability_names: ["responder-state"],
        repository_ref: "responder",
        workspace_ref: workspace_ref
      }

      try do
        assert {:ok, first} =
                 ControlPlane.place_session(Enum.at(sessions, 0).id, requirements, 60)

        assert first.worker_id == worker_id

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

  defp authorize_and_poll!(worker_id, workspace_ref) do
    certificate = "certificate-#{worker_id}"
    digest = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    assert {:ok, _worker} = ControlPlane.authorize_worker(worker_id, workspace_ref, digest)

    assert {:ok, _response} =
             ControlPlane.handle_poll(worker_id, %{
               "acknowledged_command_ids" => [],
               "command_results" => [],
               "event_batches" => [],
               "poll_ref" => "poll:#{worker_id}",
               "version" => 1,
               "worker" => %{
                 "build_version" => "coop-test",
                 "capabilities" => [%{"name" => "responder-state", "version" => "1"}],
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
                 "clock_at" => DateTime.to_iso8601(database_now!()),
                 "id" => worker_id,
                 "policy_digests" => %{"work-read-only" => @policy_digest},
                 "protocol_version" => "1",
                 "repositories" => [%{"ref" => "responder", "revision" => "commit:test"}],
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
        occurred_at: database_now!(),
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               @policy_digest,
               "responder"
             )

    session
  end

  defp cleanup!(sessions, worker_ids) do
    session_ids = Enum.map(sessions, & &1.id)
    episode_ids = Enum.map(sessions, & &1.episode_id)

    Repo.delete_all(from(placement in Placement, where: placement.session_id in ^session_ids))
    Repo.delete_all(from(session in Session, where: session.id in ^session_ids))
    Repo.delete_all(from(event in Event, where: event.episode_id in ^episode_ids))
    Repo.delete_all(from(episode in Episode, where: episode.id in ^episode_ids))
    Repo.delete_all(from(certificate in Certificate, where: certificate.worker_id in ^worker_ids))
    Repo.delete_all(from(worker in Worker, where: worker.id in ^worker_ids))
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
