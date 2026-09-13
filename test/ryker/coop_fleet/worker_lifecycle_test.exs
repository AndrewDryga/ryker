defmodule Ryker.CoopFleet.WorkerLifecycleTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.CoopFleet.{
    Certificate,
    ControlPlane,
    Enrollment,
    EnrollmentToken,
    Placement,
    Worker
  }

  alias Ryker.CoopFleet.WorkerLifecycle
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.StateTools.Binding
  alias Ryker.Work.{Custody, StateBinding}

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

  test "revocation invalidates every certificate, bootstrap token, placement, and renewal path" do
    certificate = "worker-revoke-certificate"
    digest = enroll_manual!("worker-revoke", certificate)
    heartbeat!("worker-revoke")
    session = session!("worker-revoke")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
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
               "worker-revocation-state-secret"
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

    assert {:error, :coop_worker_enrollment_not_authorized} =
             Enrollment.issue_token(
               "worker-revoke",
               "workspace-main",
               "operator:bootstrap",
               300
             )

    assert {:ok, %{status: :duplicate, worker: same}} =
             WorkerLifecycle.revoke("worker-revoke", "operator:other")

    assert same.certificate_sha256 == digest
    assert same.revoked_by == "operator:security"

    assert WorkerLifecycle.resume("worker-revoke", "operator:security") ==
             {:error, :coop_worker_revoked}
  end

  test "unknown and malformed lifecycle requests fail closed" do
    assert WorkerLifecycle.drain("missing-worker", "operator:andrew") ==
             {:error, :coop_worker_not_found}

    assert WorkerLifecycle.revoke("", "operator:andrew") ==
             {:error, {:invalid_coop_worker_lifecycle, :worker_id}}

    assert WorkerLifecycle.resume("worker", "") ==
             {:error, {:invalid_coop_worker_lifecycle, :operator_ref}}
  end

  defp enroll_manual!(worker_id, certificate) do
    digest = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    assert {:ok, %Worker{}} =
             ControlPlane.authorize_worker(worker_id, "workspace-main", digest)

    digest
  end

  defp heartbeat!(worker_id) do
    now = database_now!()

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
                 "clock_at" => DateTime.to_iso8601(now),
                 "id" => worker_id,
                 "policy_digests" => %{"work-read-only" => String.duplicate("b", 64)},
                 "protocol_version" => "1",
                 "repositories" => [%{"ref" => "ryker", "revision" => "commit:test"}],
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
        occurred_at: database_now!(),
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("b", 64),
               "ryker"
             )

    session
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
