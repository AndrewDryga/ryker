defmodule Ryker.CoopFleet.MachineAdmissionTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.CoopFleet.{Command, ControlPlane, JobSpec, JobTemplates}
  alias Ryker.CoopFleet.{Machine, MachineResources, Worker}
  alias Ryker.Episodes
  alias Ryker.Fixtures.{CoopWorkers, ModelAccess, WorkerJob, WorkSessions}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  setup do
    context = ModelAccess.create!()
    Repo.delete!(context.placement)
    context
  end

  test "negotiation and connector restart hold new placement without rejecting control polls", %{
    certificate: certificate
  } do
    poll = poll("model-worker")

    assert {:ok, _} =
             ControlPlane.handle_poll_certificate(certificate, poll, machine_report: true)

    worker = Repo.get!(Worker, "model-worker")
    assert worker.state == :busy
    assert worker.machine_report_required
    refute Machine.available?(worker)

    assert {:ok, _} =
             ControlPlane.handle_poll_certificate(certificate, report(poll, "a", 8_000, 32))

    assert Machine.available?(Repo.get!(Worker, "model-worker"))
    assert {:ok, _} = ControlPlane.handle_poll_certificate(certificate, poll)
    refute Machine.available?(Repo.get!(Worker, "model-worker"))
    assert Repo.get!(Worker, "model-worker").machine_daemon == String.duplicate("a", 64)
  end

  test "daemon identity cannot be changed or registered twice, even after revocation", %{
    certificate: certificate
  } do
    assert {:ok, _} =
             ControlPlane.handle_poll_certificate(
               certificate,
               report(poll("model-worker"), "a", 8_000, 32)
             )

    assert ControlPlane.handle_poll_certificate(
             certificate,
             report(poll("model-worker"), "b", 8_000, 32)
           ) == {:error, {:coop_worker_machine_changed, "model-worker"}}

    other = "other-machine-certificate"
    {:ok, _} = CoopWorkers.authorize("other-worker", "model-pool", digest(other))

    assert {:error, _} =
             ControlPlane.handle_poll_certificate(
               other,
               report(poll("other-worker"), "a", 8_000, 32)
             )

    {:ok, _} = Ryker.CoopFleet.WorkerLifecycle.revoke("model-worker", "test")

    assert {:error, _} =
             ControlPlane.handle_poll_certificate(
               other,
               report(poll("other-worker"), "a", 8_000, 32)
             )
  end

  test "ordinary work fits beside a warm session on a stock four-core VM", %{
    certificate: certificate,
    session: session
  } do
    poll = report(poll("model-worker"), "a", 3_000, 5)
    {:ok, _} = ControlPlane.handle_poll_certificate(certificate, poll)
    worker = Repo.get!(Worker, "model-worker")
    routing = JobTemplates.execution(%Ryker.Settings.Work{}, :admission, false)["resources"]
    work = JobTemplates.execution(%Ryker.Settings.Work{}, :contributor, true)
    machine = worker.capacity["machine"]

    free =
      machine
      |> Map.update!("free_cpu_millis", &(&1 - routing["cpu_millis"]))
      |> Map.update!("free_memory_bytes", &(&1 - routing["memory_bytes"]))

    worker = %{worker | capacity: Map.put(worker.capacity, "machine", free)}
    assert MachineResources.fits?(worker, %{session | worker_job_document: work}, Repo.now!())
  end

  test "placement skips an undersized worker and reserves unbound CPU and RAM", %{
    certificate: certificate,
    session: session
  } do
    {:ok, _} =
      ControlPlane.handle_poll_certificate(
        certificate,
        report(poll("model-worker"), "a", 2_000, 4)
      )

    large = "larger-machine-certificate"
    {:ok, _} = CoopWorkers.authorize("larger-worker", "model-pool", digest(large))

    {:ok, _} =
      ControlPlane.handle_poll_certificate(large, report(poll("larger-worker"), "b", 6_000, 24))

    assert {:ok, first} = ControlPlane.place_session(session.id, requirements(), 60)
    assert first.worker_id == "larger-worker"

    assert {:ok, _queued} = enqueue(first, session)

    # An uncertain create never loses its reservation simply by becoming old.
    first |> Ecto.Changeset.change(inserted_at: DateTime.add(Repo.now!(), -600)) |> Repo.update!()
    next = next_session!()
    assert {:error, _} = ControlPlane.place_session(next.id, requirements(), 60)
    session |> Ecto.Changeset.change(coop_session_id: "bound-session") |> Repo.update!()
    # Once bound, the worker report owns active/warm allocation accounting.
    assert {:ok, second} = ControlPlane.place_session(next.id, requirements(), 60)
    assert second.worker_id == "larger-worker"
  end

  test "an abandoned placement releases its capacity and a late submit must reacquire it", %{
    certificate: certificate,
    session: session
  } do
    {:ok, _} =
      ControlPlane.handle_poll_certificate(
        certificate,
        report(poll("model-worker"), "a", 6_000, 24)
      )

    {:ok, first} = ControlPlane.place_session(session.id, requirements(), 60)
    first |> Ecto.Changeset.change(inserted_at: DateTime.add(Repo.now!(), -600)) |> Repo.update!()
    next = next_session!()
    assert {:ok, second} = ControlPlane.place_session(next.id, requirements(), 60)
    assert enqueue(first, session) == {:error, {:coop_worker_capacity_unavailable, session.id}}
    refute Repo.exists?(Command.Query.by_placement_id(first.id))
    assert {:ok, refused} = enqueue(second, next)

    refused
    |> Command.Changeset.fail(
      Repo.now!(),
      %{"code" => "operation_not_enqueued"},
      digest("refused")
    )
    |> Repo.update!()

    assert {:ok, _command} = enqueue(first, session)
  end

  defp enqueue(placement, session) do
    ControlPlane.enqueue_command(
      placement.id,
      "create_session",
      %{
        "external_ref" => Ryker.Work.Session.coop_task_ref(session),
        "job" => session.worker_job_document,
        "job_digest" => session.worker_job_digest
      },
      "test-create:#{session.id}"
    )
  end

  test "machine reports reject missing, malformed, inconsistent and overflowing fields" do
    report = %{
      "daemon" => String.duplicate("c", 64),
      "cpu_millis" => 8_000,
      "memory_bytes" => 32 * 1_073_741_824,
      "free_cpu_millis" => 8_000,
      "free_memory_bytes" => 32 * 1_073_741_824
    }

    assert Machine.validate(report) == :ok

    for invalid <- [
          Map.delete(report, "daemon"),
          Map.put(report, "daemon", "bad"),
          Map.put(report, "extra", 1),
          Map.put(report, "cpu_millis", 0),
          Map.put(report, "memory_bytes", 9_223_372_036_854_775_808),
          Map.put(report, "free_cpu_millis", 8_001),
          Map.put(report, "free_memory_bytes", -1),
          Map.put(report, "cpu_millis", 1.5)
        ] do
      assert Machine.validate(invalid) == {:error, {:invalid_coop_worker_protocol, :machine}}
    end
  end

  defp next_session! do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "machine:#{id}",
          native_input_id: "machine:#{id}",
          occurred_at: Repo.now!(),
          turn_ref: "machine:#{id}"
        })
      )

    {:ok, session} =
      WorkSessions.pin_episode(id, "work-read-only", String.duplicate("b", 64),
        repository_ref: "ryker"
      )

    session = WorkerJob.pin!(session)
    {:ok, _} = JobSpec.digest(session.worker_job_document)
    session
  end

  defp requirements,
    do: %{capability_names: [], repository_ref: "ryker", workspace_ref: "model-pool"}

  defp poll(id) do
    path = Path.expand("../../../testdata/protocol/coop-worker-v2.json", __DIR__)
    poll = path |> File.read!() |> Jason.decode!() |> Map.fetch!("poll")

    %{
      poll
      | "poll_ref" => Ecto.UUID.generate(),
        "acknowledged_command_ids" => [],
        "command_results" => [],
        "event_batches" => [],
        "worker" => %{
          poll["worker"]
          | "id" => id,
            "workspace_ref" => "model-pool",
            "clock_at" => DateTime.to_iso8601(Repo.now!()),
            "state" => "eligible",
            "capacity" => %{
              "session_slots_free" => 8,
              "session_slots_total" => 8,
              "turn_slots_free" => 8,
              "turn_slots_total" => 8,
              "workspace_slots_free" => 8,
              "workspace_slots_total" => 8,
              "state" => "eligible",
              "cooldown_until" => nil
            }
        }
    }
  end

  defp report(poll, daemon, cpu, gib) do
    put_in(poll, ["worker", "capacity", "machine"], %{
      "daemon" => String.duplicate(daemon, 64),
      "cpu_millis" => cpu,
      "free_cpu_millis" => cpu,
      "memory_bytes" => gib * 1_073_741_824,
      "free_memory_bytes" => gib * 1_073_741_824
    })
  end
end
