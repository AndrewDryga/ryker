defmodule Ryker.CoopFleet.WorkerLifecycleTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Query
  alias Ryker.CoopFleet.{Certificate, ControlPlane, Enrollment, EnrollmentToken, Placement}
  alias Ryker.CoopFleet.Worker
  alias Ryker.CoopFleet.WorkerLifecycle
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Release
  alias Ryker.StateTools.Binding
  alias Ryker.Work.{Custody, StateBinding}

  # Moving workers off the controller disk must not strand the jobs already
  # placed there. An upgrade drain also holds their later turns and cleanup.
  test "stopping admission preserves the original decision across heartbeats and upgrade drains" do
    enroll_manual!("worker-retiring", "worker-retiring-certificate")
    heartbeat!("worker-retiring")

    assert {:ok, %{status: :admission_stopped, worker: stopped}} =
             WorkerLifecycle.stop_admission("worker-retiring", "operator:pool-migration")

    assert stopped.state == :eligible
    assert stopped.admission_stopped_at
    assert stopped.admission_stopped_by == "operator:pool-migration"

    assert {:ok, %{status: :duplicate, worker: duplicate}} =
             WorkerLifecycle.stop_admission("worker-retiring", "operator:other")

    assert duplicate.admission_stopped_at == stopped.admission_stopped_at
    assert duplicate.admission_stopped_by == stopped.admission_stopped_by
    heartbeat!("worker-retiring")
    owner = "operator:worker-upgrade:retiring-test"
    assert {:ok, %{worker: drained}} = WorkerLifecycle.drain("worker-retiring", owner)

    assert {:ok, %{worker: resumed}} =
             WorkerLifecycle.resume_if_drained_by(
               "worker-retiring",
               owner,
               drained.drain_requested_at
             )

    assert resumed.admission_stopped_at == stopped.admission_stopped_at
    assert resumed.admission_stopped_by == stopped.admission_stopped_by

    assert {:ok, %{status: :admission_started, worker: accepting}} =
             WorkerLifecycle.start_admission("worker-retiring", "operator:pool-migration")

    assert accepting.admission_stopped_at == nil
    assert accepting.admission_stopped_by == nil
  end

  test "drain is audited, idempotent, reversible, and removes placement eligibility" do
    certificate = "worker-drain-certificate"
    enroll_manual!("worker-drain", certificate)

    assert {:ok, %{status: :draining, worker: drained}} =
             WorkerLifecycle.drain("worker-drain", "operator:andrew")

    assert drained.state == :draining
    assert drained.drain_requested_at
    assert drained.drain_requested_by == "operator:andrew"

    assert {:ok, %{status: :duplicate, worker: duplicate}} =
             WorkerLifecycle.drain("worker-drain", "operator:other")

    assert duplicate.drain_requested_by == "operator:andrew"

    assert {:ok, %{status: :resumed, worker: resumed}} =
             WorkerLifecycle.resume("worker-drain", "operator:andrew")

    assert resumed.state == :offline
    assert resumed.drain_requested_at == nil
    assert resumed.drain_requested_by == nil
  end

  test "pool activation cannot clear another operator's or a replaced admission hold" do
    enroll_manual!("worker-pool-guard", "pool-guard-certificate")

    assert {:ok, %{worker: held}} =
             WorkerLifecycle.stop_admission("worker-pool-guard", "operator:pool")

    assert WorkerLifecycle.start_admission_if_stopped_by(
             "worker-pool-guard",
             "operator:other",
             held.admission_stopped_at
           ) == {:error, :coop_worker_admission_changed}

    assert WorkerLifecycle.start_admission_if_stopped_by(
             "worker-pool-guard",
             "operator:pool",
             DateTime.add(held.admission_stopped_at, -1)
           ) == {:error, :coop_worker_admission_changed}

    assert {:ok, %{status: :admission_started}} =
             WorkerLifecycle.start_admission_if_stopped_by(
               "worker-pool-guard",
               "operator:pool",
               held.admission_stopped_at
             )

    assert {:ok, %{worker: replacement}} =
             WorkerLifecycle.stop_admission("worker-pool-guard", "operator:manual")

    assert WorkerLifecycle.start_admission_if_stopped_by(
             "worker-pool-guard",
             "operator:pool",
             held.admission_stopped_at
           ) == {:error, :coop_worker_admission_changed}

    assert Repo.peek(Worker.Query.by_id("worker-pool-guard")).admission_stopped_at ==
             replacement.admission_stopped_at
  end

  # PostgreSQL JSON omits trailing fractional zeros. A recovered pool receipt
  # must not strand admission or an upgrade just because its encoding changed.
  test "SQL receipt precision preserves the exact admission and drain instant" do
    enroll_manual!("worker-sql-receipt", "sql-receipt-certificate")
    instant = ~U[2026-11-03 10:00:00.123450Z]
    timestamp = "2026-11-03T10:00:00.12345+00:00"
    owner = "operator:worker-upgrade:pool:precision-test"

    {1, nil} =
      Repo.update_all(Worker.Query.by_id("worker-sql-receipt"),
        set: [admission_stopped_at: instant, admission_stopped_by: owner]
      )

    assert {:ok, %{status: :admission_started}} =
             Release.resume_worker_admission("worker-sql-receipt", owner, timestamp, log: false)

    assert {:ok, %{status: :draining}} = WorkerLifecycle.drain("worker-sql-receipt", owner)

    {1, nil} =
      Repo.update_all(Worker.Query.by_id("worker-sql-receipt"),
        set: [drain_requested_at: instant]
      )

    assert WorkerLifecycle.resume("worker-sql-receipt", "operator:manual") ==
             {:error, :coop_worker_upgrade_in_progress}

    assert {:ok, %{status: :resumed}} =
             Release.resume_worker_upgrade("worker-sql-receipt", owner, timestamp, log: false)
  end

  test "upgrade cleanup cannot resume another operator's drain or a newer drain" do
    enroll_manual!("worker-guard", "guard-certificate")
    assert {:ok, %{worker: first}} = WorkerLifecycle.drain("worker-guard", "operator:upgrade")

    assert WorkerLifecycle.resume_if_drained_by(
             "worker-guard",
             "operator:other",
             first.drain_requested_at
           ) == {:error, :coop_worker_drain_changed}

    assert {:ok, %{status: :resumed}} =
             WorkerLifecycle.resume_if_drained_by(
               "worker-guard",
               "operator:upgrade",
               first.drain_requested_at
             )

    assert {:ok, %{worker: second}} = WorkerLifecycle.drain("worker-guard", "operator:upgrade")

    assert WorkerLifecycle.resume_if_drained_by(
             "worker-guard",
             "operator:upgrade",
             DateTime.add(second.drain_requested_at, -1, :second)
           ) == {:error, :coop_worker_drain_changed}

    assert Repo.get!(Worker, "worker-guard").drain_requested_at == second.drain_requested_at
  end

  # Otherwise a console or CLI resume can admit a turn between the idle snapshot and restart.
  test "ordinary resume cannot reopen an upgrade drain before its owner finishes" do
    enroll_manual!("worker-upgrade-guard", "upgrade-guard-certificate")
    owner = "operator:worker-upgrade:exclusive-test"
    assert {:ok, %{worker: drained}} = WorkerLifecycle.drain("worker-upgrade-guard", owner)

    assert WorkerLifecycle.resume("worker-upgrade-guard", "operator:other") ==
             {:error, :coop_worker_upgrade_in_progress}

    assert WorkerLifecycle.resume("worker-upgrade-guard", owner) ==
             {:error, :coop_worker_upgrade_in_progress}

    assert Repo.get!(Worker, "worker-upgrade-guard").drain_requested_at ==
             drained.drain_requested_at

    assert {:ok, %{status: :resumed}} =
             WorkerLifecycle.resume_if_drained_by(
               "worker-upgrade-guard",
               owner,
               drained.drain_requested_at
             )
  end

  test "revocation invalidates every certificate, bootstrap token, placement, and renewal path" do
    certificate = "worker-revoke-certificate"
    digest = enroll_manual!("worker-revoke", certificate)
    heartbeat!("worker-revoke")
    session = session!("worker-revoke")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: "ryker",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, claim} = Custody.claim_next("worker:revoke-test", 60, :work)

    assert {:ok, binding} =
             StateBinding.derive(
               session,
               claim.turn,
               StateBinding.placement_scope(placement),
               "https://ryker.example/v1/state-tools/mcp",
               Ryker.Secret.new("worker-revocation-state-secret")
             )

    assert {:ok, _turn} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               binding.endpoint,
               binding.token_sha256
             )

    assert {:ok, _binding} = Binding.resolve(binding.token)

    assert {:ok, token} =
             Enrollment.issue_token(
               "worker-revoke",
               "workspace-main",
               "operator:bootstrap",
               300
             )

    assert {:ok, %{status: :revoked, worker: revoked}} =
             WorkerLifecycle.revoke("worker-revoke", "operator:security")

    assert revoked.state == :revoked
    assert revoked.revoked_at
    assert revoked.revoked_by == "operator:security"

    assert Repo.get(EnrollmentToken, token.id) == nil

    revoked_placement = Repo.get!(Placement, placement.id)
    assert revoked_placement.state == :revoking
    assert DateTime.compare(revoked_placement.lease_expires_at, revoked.revoked_at) != :gt
    assert Binding.resolve(binding.token) == {:error, :state_tools_binding_not_authorized}

    assert [%Certificate{revoked_at: %DateTime{}, revoked_by: "operator:security"}] =
             Repo.all(from(value in Certificate, where: value.worker_id == "worker-revoke"))

    assert ControlPlane.authenticate_certificate(certificate) ==
             {:error, :coop_worker_certificate_not_authorized}

    assert Enrollment.issue_token(
             "worker-revoke",
             "workspace-main",
             "operator:bootstrap",
             300
           ) == {:error, :coop_worker_enrollment_not_authorized}

    assert {:ok, %{status: :duplicate, worker: same}} =
             WorkerLifecycle.revoke("worker-revoke", "operator:other")

    assert same.certificate_sha256 == digest
    assert same.revoked_by == "operator:security"

    assert WorkerLifecycle.resume("worker-revoke", "operator:security") ==
             {:error, :coop_worker_revoked}
  end

  test "unknown and malformed lifecycle requests fail closed" do
    assert WorkerLifecycle.stop_admission("missing-worker", "operator:cutover") ==
             {:error, :coop_worker_not_found}

    assert WorkerLifecycle.start_admission("worker", "") ==
             {:error, {:invalid_coop_worker_lifecycle, :operator_ref}}

    assert WorkerLifecycle.drain("missing-worker", "operator:andrew") ==
             {:error, :coop_worker_not_found}

    assert WorkerLifecycle.revoke("", "operator:andrew") ==
             {:error, {:invalid_coop_worker_lifecycle, :worker_id}}

    assert WorkerLifecycle.resume("worker", "") ==
             {:error, {:invalid_coop_worker_lifecycle, :operator_ref}}
  end

  test "reopening admission cannot clear a drain or revive a revoked worker" do
    enroll_manual!("worker-admission-fence", "worker-admission-fence-certificate")
    assert {:ok, _} = WorkerLifecycle.stop_admission("worker-admission-fence", "operator:cutover")

    assert {:ok, %{worker: drained}} =
             WorkerLifecycle.drain("worker-admission-fence", "operator:pause")

    assert {:ok, %{worker: accepting}} =
             WorkerLifecycle.start_admission("worker-admission-fence", "operator:cutover")

    assert accepting.drain_requested_at == drained.drain_requested_at
    assert accepting.drain_requested_by == drained.drain_requested_by
    assert accepting.state == :draining
    assert {:ok, _} = WorkerLifecycle.revoke("worker-admission-fence", "operator:security")

    assert WorkerLifecycle.start_admission("worker-admission-fence", "operator:cutover") ==
             {:error, :coop_worker_revoked}

    assert WorkerLifecycle.stop_admission("worker-admission-fence", "operator:cutover") ==
             {:error, :coop_worker_revoked}
  end

  defp enroll_manual!(worker_id, certificate) do
    digest = digest(certificate)

    assert {:ok, %Worker{}} =
             CoopWorkers.authorize(worker_id, "workspace-main", digest)

    digest
  end

  # Each worker here holds the certificate named after it (`enroll_manual!/2`).
  defp heartbeat!(worker_id) do
    now = Ryker.Repo.now!()

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate("#{worker_id}-certificate", %{
               "acknowledged_command_ids" => [],
               "command_results" => [],
               "event_batches" => [],
               "poll_ref" => "poll:#{worker_id}",
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
                 "clock_at" => DateTime.to_iso8601(now),
                 "id" => worker_id,
                 "protocol_version" => "2",
                 "sandbox_digest" => String.duplicate("a", 64),
                 "state" => "eligible",
                 "workspace_ref" => "workspace-main"
               }
             })
  end

  defp session!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "worker-lifecycle:#{suffix}",
        native_input_id: "source:#{suffix}",
        occurred_at: Ryker.Repo.now!(),
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             WorkSessions.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("b", 64),
               repository_ref: "ryker"
             )

    WorkerJob.pin!(session)
  end
end
