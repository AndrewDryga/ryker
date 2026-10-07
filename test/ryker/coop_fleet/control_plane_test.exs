defmodule Ryker.CoopFleet.ControlPlaneTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  import ExUnit.CaptureLog
  import Ecto.Query
  alias Ryker.Admission.FleetSession
  alias Ryker.CoopFleet.{Bodies, Client, Command, ControlPlane, Event, Placement, Worker}
  alias Ryker.CoopFleet.{WorkerLifecycle, WorkspaceCheckpointTransfer}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress.Inbox
  alias Ryker.Observability
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.StateTools.Binding
  alias Ryker.Work.{ActivityEvent, Custody, Session, StateBinding}
  alias Ryker.Work.{Cancellation, Turn}

  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  test "an authenticated heartbeat records identity capabilities and measured capacity" do
    certificate = "worker-a-client-certificate"

    assert {:ok, enrolled} =
             CoopWorkers.authorize(
               "worker-a",
               "workspace-main",
               certificate_digest(certificate)
             )

    assert enrolled.state == :offline

    poll = poll("worker-a", "workspace-main", "poll:worker-a:1")

    assert {:ok, response} = ControlPlane.handle_poll_certificate(certificate, poll)
    assert response["poll_ref"] == "poll:worker-a:1"
    assert response["commands"] == []

    worker = Repo.get!(Worker, "worker-a")
    assert worker.workspace_ref == "workspace-main"
    assert worker.state == :eligible
    assert worker.capabilities == [%{"name" => "controller-tools", "version" => "1"}]
    assert worker.capacity["turn_slots_free"] == 2
    assert worker.last_seen_at != nil

    assert {:ok, certificate_response} =
             ControlPlane.handle_poll_certificate(certificate, poll)

    assert certificate_response["poll_ref"] == "poll:worker-a:1"

    assert ControlPlane.handle_poll_certificate("wrong-certificate", poll) ==
             {:error, :coop_worker_certificate_not_authorized}

    # A worker's certificate speaks only for that worker.
    assert {:ok, _other} =
             CoopWorkers.authorize("worker-b", "workspace-main", certificate_digest("worker-b"))

    assert ControlPlane.handle_poll_certificate("worker-b", poll) ==
             {:error, {:coop_worker_identity_mismatch, "worker-b", "worker-a"}}

    wrong_workspace = put_in(poll, ["worker", "workspace_ref"], "workspace-other")

    assert ControlPlane.handle_poll_certificate(certificate, wrong_workspace) ==
             {:error, {:coop_worker_workspace_mismatch, "workspace-main", "workspace-other"}}
  end

  test "placement applies hard authority constraints and remains sticky" do
    authorize_and_poll!("worker-b", capacity: capacity(1, 4))
    authorize_and_poll!("worker-a", capacity: capacity(2, 4))
    session = session!("sticky-placement")

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    assert {:ok, placement} = ControlPlane.place_session(session.id, requirements, 60)
    assert placement.worker_id == "worker-a"
    assert placement.generation == 1
    assert placement.state == :active
    assert placement.lease_ref != nil
    assert placement.last_acked_event_sequence == 0

    authorize_and_poll!("worker-c", capacity: capacity(4, 4))

    assert {:ok, sticky} = ControlPlane.place_session(session.id, requirements, 60)
    assert sticky.id == placement.id
    assert sticky.worker_id == "worker-a"

    assert Repo.aggregate(from(p in Placement, where: p.session_id == ^session.id), :count) == 1
  end

  test "versioned placement excludes an otherwise eligible legacy worker" do
    authorize_and_poll!("worker-legacy", capacity: capacity(4, 4))

    authorize_and_poll!("worker-freshness-v2",
      capabilities: [
        %{"name" => "controller-tools", "version" => "1"},
        %{"name" => "repository-freshness", "version" => "2"}
      ],
      capacity: capacity(2, 4)
    )

    session = session!("versioned-placement")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 capability_versions: %{"repository-freshness" => "2"},
                 repository_ref: "ryker",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert placement.worker_id == "worker-freshness-v2"

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-freshness-v2",
               poll(
                 "worker-freshness-v2",
                 "workspace-main",
                 "poll:worker-freshness-v2:daemon-regressed"
               )
             )

    assert Repo.get!(Placement, placement.id).state == :revoking
  end

  # Every job Ryker freezes is a version-2 JobSpec since Coop's job-setup:2 (Coop 33ea84fe),
  # and a worker without it refuses one: placing work there would only fail on the worker.
  test "work is placed only on workers that run version-2 jobs" do
    assert Client.capability_versions() == %{
             "job-setup" => "2",
             "repository-freshness" => "2"
           }

    authorize_and_poll!("worker-job-v1",
      capabilities: [
        %{"name" => "controller-tools", "version" => "1"},
        %{"name" => "repository-freshness", "version" => "2"}
      ]
    )

    session = session!("job-setup-placement")

    requirements = %{
      capability_names: ["controller-tools"],
      capability_versions: Client.capability_versions(),
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    refute ControlPlane.worker_available?(session, requirements)

    authorize_and_poll!("worker-job-v2",
      capabilities: [
        %{"name" => "controller-tools", "version" => "1"},
        %{"name" => "job-setup", "version" => "2"},
        %{"name" => "repository-freshness", "version" => "2"}
      ]
    )

    assert {:ok, placement} = ControlPlane.place_session(session.id, requirements, 60)
    assert placement.worker_id == "worker-job-v2"
  end

  test "admission classification places on the fleet without inventing an episode" do
    authorize_and_poll!("worker-admission")

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Classify remotely."},
               event_kind: :message,
               event_ref: "Ev-fleet-control-admission",
               message_ref: "1787832000.000100",
               occurred_at: Repo.now!(),
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE4A6CC529D81"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, session} =
             FleetSession.ensure(entry, %{name: "work-read-only", digest: @policy_digest})

    session = WorkerJob.pin!(session)

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: nil,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert placement.session_id == session.id
    assert placement.episode_id == nil
    assert placement.worker_id == "worker-admission"
  end

  test "worker-reported free capacity is not reduced by existing placements twice" do
    authorize_and_poll!("worker-a", capacity: capacity(2, 4))
    first = session!("free-capacity-first")

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    assert {:ok, first_placement} = ControlPlane.place_session(first.id, requirements, 60)
    assert first_placement.worker_id == "worker-a"

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:one-free",
                 capacity: capacity(1, 4)
               )
             )

    second = session!("free-capacity-second")

    assert ControlPlane.place_session(second.id, requirements, 60) ==
             {:error, {:coop_worker_capacity_unavailable, second.id}}

    first |> Ecto.Changeset.change(coop_session_id: "coop-free-capacity-first") |> Repo.update!()

    assert {:ok, _} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:bound-one-free",
                 capacity: capacity(1, 4)
               )
             )

    assert {:ok, second_placement} = ControlPlane.place_session(second.id, requirements, 60)
    assert second_placement.worker_id == "worker-a"
  end

  # A create Coop refuses for good leaves its session active and unbound, and
  # the worker renews that placement on every poll. Counted as a create still
  # under way, it held a slot until retention retired the session, and a few
  # of them left a worker that reported free slots with nothing placed on it.
  test "a create left over from long ago stops holding a worker slot" do
    authorize_and_poll!("worker-leftover-create", capacity: capacity(1, 1))
    leftover = place!("leftover-create")
    next = session!("after-leftover-create")

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    # A create under way holds the only slot the worker reported free.
    assert ControlPlane.place_session(next.id, requirements, 60) ==
             {:error, {:coop_worker_capacity_unavailable, next.id}}

    {1, nil} =
      Repo.update_all(from(placement in Placement, where: placement.id == ^leftover.id),
        set: [inserted_at: DateTime.add(Repo.now!(), -301, :second)]
      )

    # The worker still renews the left-over placement and reports its slot free.
    idle_poll!("worker-leftover-create", "renews-leftover", capacity(1, 1))
    assert Repo.get!(Placement, leftover.id).state == :active

    assert {:ok, placement} = ControlPlane.place_session(next.id, requirements, 60)
    assert placement.worker_id == "worker-leftover-create"
  end

  test "placement reservations and leases use the same database clock" do
    # Host/database clock drift made freshly reported capacity count an existing
    # placement twice, blocking the next conversation even with a free worker slot.
    authorize_and_poll!("worker-a")
    session = session!("reservation-database-clock")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{repository_ref: "ryker", workspace_ref: "workspace-main"},
               60
             )

    assert placement.inserted_at == DateTime.add(placement.lease_expires_at, -60, :second)
  end

  test "fresh worker capacity can reuse slots held only by reflected parked placements" do
    # Two parked live sessions filled the placement ledger while the worker reported both
    # slots free, blocking every later Slack conversation before it could start.
    authorize_and_poll!("worker-a", capacity: capacity(2, 2))

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    first = session!("reflected-capacity-first")
    assert {:ok, _placement} = ControlPlane.place_session(first.id, requirements, 60)

    # Only the validated create receipt binds a session. A heartbeat alone
    # cannot prove that this placement has reached the worker.
    first |> Ecto.Changeset.change(coop_session_id: "coop-reflected-first") |> Repo.update!()

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:first-reflected",
                 capacity: capacity(1, 2)
               )
             )

    second = session!("reflected-capacity-second")
    assert {:ok, _placement} = ControlPlane.place_session(second.id, requirements, 60)
    second |> Ecto.Changeset.change(coop_session_id: "coop-reflected-second") |> Repo.update!()

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:both-parked",
                 capacity: capacity(2, 2)
               )
             )

    next = session!("capacity-after-reflected-placements")
    assert {:ok, placement} = ControlPlane.place_session(next.id, requirements, 60)
    assert placement.worker_id == "worker-a"
  end

  test "an evidence export the worker advertises can be queued for it" do
    # Found live 2026-09-12: the production worker advertised session-evidence:1
    # all day and coop_session_evidence stayed empty, because the enqueue
    # authority kept a private copy of the command vocabulary and that copy
    # never learned the kind the wire contract already carried. Every capture
    # was refused as :command_kind before a worker ever saw it, and nothing in
    # the client tests noticed because they answer through a fake bridge.
    authorize_and_poll!("worker-a", capacity: capacity(1, 1))
    placement = place!("session-evidence-command")

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "get_session_evidence",
               %{"coop_session_id" => "coop-session-evidence-command"},
               "ryker:test:session-evidence-command"
             )

    assert command.kind == "get_session_evidence"

    assert {:ok, %{"commands" => [delivered]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:session-evidence")
             )

    assert delivered["kind"] == "api_request"

    assert delivered["payload"] == %{
             "method" => "GET",
             "path" => "/v1/sessions/coop-session-evidence-command/evidence"
           }
  end

  test "failed body preparation cannot roll back another result or the worker heartbeat" do
    authorize_and_poll!("worker-a")
    placement = place!("body-outage")

    assert {:ok, ready} =
             ControlPlane.enqueue_command(
               placement.id,
               "get_session",
               %{"coop_session_id" => "s"},
               "body:ready"
             )

    assert {:ok, %{"commands" => [_]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "body:deliver")
             )

    assert {:ok, deferred} =
             ControlPlane.enqueue_command(
               placement.id,
               "api_request",
               %{
                 "method" => "POST",
                 "path" => "/v1/sessions/s/turns",
                 "body" => %{"prompt" => String.duplicate("p", 300 * 1_024)}
               },
               "body:deferred"
             )

    assert {:ok, invalid} =
             ControlPlane.enqueue_command(placement.id, "create_session", %{}, "body:invalid")

    old_expiry = DateTime.add(Repo.now!(), 1, :second)
    placement |> Ecto.Changeset.change(lease_expires_at: old_expiry) |> Repo.update!()

    result = %{
      "command_id" => ready.id,
      "operation_key" => ready.idempotency_key,
      "state" => "succeeded",
      "error" => nil,
      "resource" => %{"status" => 200, "body" => %{"id" => "s"}}
    }

    # An unavailable body root affects only the command which needs that storage.
    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "body:outage", command_results: [result]),
               body_root: nil
             )

    assert response["commands"] == []
    assert response["acknowledged_result_command_ids"] == [ready.id]
    assert Repo.get!(Command, deferred.id).status == :queued
    assert Repo.get!(Command, invalid.id).error["code"] == "invalid_command"

    assert DateTime.compare(Repo.get!(Placement, placement.id).lease_expires_at, old_expiry) ==
             :gt
  end

  test "a successfully closed session no longer reserves a reported worker slot" do
    # Two recovered Slack runs closed remotely but their still-current placement
    # rows consumed every host reservation, so all fresh work was blocked even
    # while the worker reported those two session slots as free.
    authorize_and_poll!("worker-a", capacity: capacity(1, 1))
    closed_placement = place!("closed-placement-capacity")

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               closed_placement.id,
               "close_session",
               %{"coop_session_id" => "coop-closed-placement-capacity", "expected_revision" => 1},
               "ryker:test:closed-placement-capacity"
             )

    assert {:ok, %{"commands" => [%{"command_id" => command_id}]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:close-capacity:deliver",
                 capacity: capacity(0, 1)
               )
             )

    assert command_id == command.id

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:close-capacity:complete",
                 capacity: capacity(1, 1),
                 command_results: [
                   %{
                     "command_id" => command.id,
                     "error" => nil,
                     "operation_key" => command.idempotency_key,
                     "resource" => %{
                       "status" => 200,
                       "body" => %{
                         "session" => %{
                           "id" => "coop-closed-placement-capacity",
                           "state" => "closed"
                         }
                       }
                     },
                     "state" => "succeeded"
                   }
                 ]
               )
             )

    next = session!("capacity-after-close")

    assert {:ok, next_placement} =
             ControlPlane.place_session(
               next.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: "ryker",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert next_placement.worker_id == "worker-a"
  end

  # Coop answers a prepare only once the agent is running, after waiting for
  # a free runtime slot, and the worker runs one command at a time: a prepare
  # sent to a worker with anything else to do would hold every other command
  # on it, a routing turn's included, for as long as that takes.
  test "a worker is idle only with every slot free, no session starting and no command waiting" do
    authorize_and_poll!("worker-idle", capacity: capacity(4, 4))
    placement = place!("idle-prepare")
    session = Repo.get!(Session, placement.session_id)

    # Its own create still outstanding reserves a slot.
    refute ControlPlane.worker_idle?(session.id)
    bind!(session, "coop-idle-prepare")
    assert ControlPlane.worker_idle?(session.id)

    idle_poll!("worker-idle", "one-slot-used", capacity(3, 4))
    refute ControlPlane.worker_idle?(session.id)
    idle_poll!("worker-idle", "every-slot-free", capacity(4, 4))
    assert ControlPlane.worker_idle?(session.id)

    starting = place!("idle-another-starting")
    refute ControlPlane.worker_idle?(session.id)
    bind!(Repo.get!(Session, starting.session_id), "coop-idle-another")
    assert ControlPlane.worker_idle?(session.id)

    # A placement whose create never finished, left over from long ago, is
    # not a session being created, and must not stop every prepare for good.
    leftover = place!("idle-leftover")
    refute ControlPlane.worker_idle?(session.id)

    {1, nil} =
      Repo.update_all(from(placement in Placement, where: placement.id == ^leftover.id),
        set: [inserted_at: DateTime.add(Repo.now!(), -301, :second)]
      )

    assert ControlPlane.worker_idle?(session.id)

    assert {:ok, _command} =
             ControlPlane.enqueue_command(
               starting.id,
               "get_session",
               %{"coop_session_id" => "coop-idle-another"},
               "ryker:test:idle-waiting-command"
             )

    refute ControlPlane.worker_idle?(session.id)

    # A session no worker holds has none to ask.
    refute ControlPlane.worker_idle?(session!("idle-unplaced").id)
  end

  # A prepare holds the worker's one command slot until Coop has the agent
  # running, and Coop allows it the job's hour-long turn timeout. Each
  # redelivery renews a running command's lease on the worker, so without a
  # bound an agent that never starts would hold every other command on that
  # worker for an hour. Redelivered for a minute at most, its lease runs out
  # and the worker cancels it.
  test "a prepare is redelivered for a minute at most, so a stuck one cannot hold its worker" do
    authorize_and_poll!("worker-stuck-prepare", capacity: capacity(4, 4))
    placement = place!("stuck-prepare")

    assert {:ok, prepare} =
             ControlPlane.enqueue_command(
               placement.id,
               "prepare_session",
               %{"coop_session_id" => "coop-stuck-prepare", "expected_revision" => 1},
               "ryker:test:stuck-prepare"
             )

    assert [prepare.id] == delivered!("worker-stuck-prepare", "first")
    assert [prepare.id] == delivered!("worker-stuck-prepare", "renewed")

    {1, nil} =
      Repo.update_all(from(command in Command, where: command.id == ^prepare.id),
        set: [delivered_at: DateTime.add(Repo.now!(), -61, :second)]
      )

    assert {:ok, read} =
             ControlPlane.enqueue_command(
               placement.id,
               "get_session",
               %{"coop_session_id" => "coop-stuck-prepare"},
               "ryker:test:stuck-prepare:read"
             )

    assert [read.id] == delivered!("worker-stuck-prepare", "past-a-minute")
  end

  # Coop sends no result for a command whose lease ran out before it ran, and a placement that
  # ends leaves its delivered commands as they were, so they stayed "delivered" for good and the
  # worker never counted as idle again: no routing session was ever prepared on it, and every
  # message waited for its box and agent to start (2026-10-04 review).
  test "commands nobody will answer do not keep their worker busy" do
    authorize_and_poll!("worker-forgotten", capacity: capacity(4, 4))
    placement = place!("forgotten-prepare")
    session = Repo.get!(Session, placement.session_id)
    bind!(session, "coop-forgotten-prepare")
    assert ControlPlane.worker_idle?(session.id)

    # A prepare delivered more than a minute ago is never delivered again.
    assert {:ok, prepare} =
             ControlPlane.enqueue_command(
               placement.id,
               "prepare_session",
               %{"coop_session_id" => "coop-forgotten-prepare", "expected_revision" => 1},
               "ryker:test:forgotten-prepare"
             )

    assert [prepare.id] == delivered!("worker-forgotten", "prepare")
    refute ControlPlane.worker_idle?(session.id)

    {1, nil} =
      Repo.update_all(from(command in Command, where: command.id == ^prepare.id),
        set: [delivered_at: DateTime.add(Repo.now!(), -61, :second)]
      )

    assert ControlPlane.worker_idle?(session.id)

    # A command delivered on a placement that has since ended is answered by nobody.
    ended = place!("forgotten-ended")
    bind!(Repo.get!(Session, ended.session_id), "coop-forgotten-ended")

    assert {:ok, read} =
             ControlPlane.enqueue_command(
               ended.id,
               "get_session",
               %{"coop_session_id" => "coop-forgotten-ended"},
               "ryker:test:forgotten-read"
             )

    assert [read.id] == delivered!("worker-forgotten", "read")
    refute ControlPlane.worker_idle?(session.id)

    {1, nil} =
      Repo.update_all(from(placement in Placement, where: placement.id == ^ended.id),
        set: [state: :replaced]
      )

    assert ControlPlane.worker_idle?(session.id)
  end

  test "sandbox drift revokes placement renewal before another command is delivered" do
    authorize_and_poll!("worker-a")
    placement = place!("authority-drift")

    session = Repo.get!(Session, placement.session_id)

    assert placement.requirements == %{
             "capability_names" => ["controller-tools"],
             "capability_versions" => %{},
             "job_ref" => session.external_ref,
             "job_digest" => session.worker_job_digest,
             "sandbox_digest" => @sandbox_digest,
             "workspace_ref" => "workspace-main"
           }

    assert {:ok, _command} =
             ControlPlane.enqueue_command(
               placement.id,
               "create_session",
               %{"external_ref" => "episode-authority-drift"},
               "ryker:work:create:authority-drift:g1"
             )

    changed =
      poll("worker-a", "workspace-main", "poll:worker-a:authority-drift")
      |> put_in(
        ["worker", "sandbox_digest"],
        String.duplicate("e", 64)
      )

    assert {:ok, %{"commands" => []}} = ControlPlane.handle_poll_certificate("worker-a", changed)
    assert Repo.get!(Placement, placement.id).state == :revoking

    assert Repo.get_by!(Command, idempotency_key: "ryker:work:create:authority-drift:g1").status ==
             :queued

    # A revoking placement is never selected by renewal again, so before this it
    # stayed "current" forever: after a worker rolled to a new build, six expired
    # revoking placements kept readiness red with :expired_current_placements
    # with nothing able to clear them.
    Repo.update_all(
      from(placement in Placement, where: placement.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    assert {:ok, %{"commands" => []}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:authority-drift-expired")
             )

    assert Repo.get!(Placement, placement.id).state == :replaced

    assert Repo.get_by!(Command, idempotency_key: "ryker:work:create:authority-drift:g1").status ==
             :failed
  end

  test "a corrupt frozen job is refused before placement even when a worker is ready" do
    authorize_and_poll!("worker-ready")
    session = session!("corrupt-job")

    Repo.update_all(from(s in Session, where: s.id == ^session.id),
      set: [worker_job_digest: String.duplicate("f", 64)]
    )

    assert {:error, {:coop_fleet_authority_mismatch, :worker_job}} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 workspace_ref: "workspace-main"
               },
               60
             )

    refute Repo.exists?(from(p in Placement, where: p.session_id == ^session.id))
  end

  test "an expired placement is terminalized and requires a new immutable Work session" do
    authorize_and_poll!("worker-a")
    placement = place!("expired-placement")

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "get_session",
               %{"session_ref" => placement.session_id},
               "ryker:test:expired-placement-read"
             )

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(Repo.now!(), -1, :second)]
    )

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    assert {:error, {:coop_session_replacement_required, session_id, generation}} =
             ControlPlane.place_session(placement.session_id, requirements, 60)

    assert session_id == placement.session_id
    assert generation == placement.generation
    assert Repo.get!(Placement, placement.id).state == :replaced

    # Four reads that never left Ryker stayed queued after failover and kept
    # readiness red for every otherwise healthy request until operator repair.
    failed_command = Repo.get!(Command, command.id)
    assert failed_command.status == :failed
    assert failed_command.error["code"] == "operation_not_enqueued"
    assert failed_command.operation_key == command.idempotency_key
    assert failed_command.completed_at != nil

    assert {:error, {:coop_session_replacement_required, ^session_id, ^generation}} =
             ControlPlane.place_session(placement.session_id, requirements, 60)

    assert Repo.aggregate(from(p in Placement, where: p.session_id == ^session_id), :count) == 1
  end

  test "a cancelling bound session reacquires only its previous worker after lease loss" do
    authorize_and_poll!("worker-a")
    session = session!("cancel-placement-recovery")

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    assert {:ok, placement} = ControlPlane.place_session(session.id, requirements, 60)

    {1, nil} =
      Repo.update_all(
        from(value in Session, where: value.id == ^session.id),
        set: [coop_session_id: "coop-cancel-placement-recovery"]
      )

    assert {:ok, claim} =
             Custody.claim_next("worker:cancel-placement-recovery", 60, :work)

    turn = claim.turn

    assert {:ok, intent} = Cancellation.new_block("placement lease ended")

    turn
    |> Turn.Changeset.prepare_cancellation(
      intent,
      Cancellation.fingerprint(intent),
      nil
    )
    |> Repo.update!()

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(Repo.now!(), -1, :second)]
    )

    assert {:error, {:coop_session_replacement_required, _, 1}} =
             ControlPlane.place_session(session.id, requirements, 60)

    # The two production cancellations could not reach the Coop sessions that
    # were still present on their original worker, so both stayed pending forever.
    assert {:ok, recovered} = ControlPlane.place_session(session.id, requirements, 60)
    assert recovered.generation == 2
    assert recovered.worker_id == placement.worker_id
    assert recovered.state == :active
  end

  # A session the worker still holds is not lost work — only the placement that addressed it is.
  # Replacing the session is the right answer when its material is gone, and the wrong one when the
  # material is there: it discards the material, and a publication review cannot survive that at all
  # because the session IS what it reviews. Publication e11291b3 deferred once a minute for 1500
  # attempts on exactly this. Re-placement stays on the SAME worker, and the new generation fences
  # every command the old placement had.
  test "a bound session reacquires its busy worker without reserving another slot" do
    authorize_and_poll!("worker-a")
    session = session!("bound-placement-recovery")

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    assert {:ok, placement} = ControlPlane.place_session(session.id, requirements, 60)

    {1, nil} =
      Repo.update_all(
        from(value in Session, where: value.id == ^session.id),
        set: [coop_session_id: "coop-bound-placement-recovery"]
      )

    busy =
      poll("worker-a", "workspace-main", "poll:worker-a:busy")
      |> put_in(["worker", "state"], "busy")
      |> put_in(["worker", "capacity"], %{capacity(0, 4) | "state" => "busy"})

    assert {:ok, _} = ControlPlane.handle_poll_certificate("worker-a", busy)

    assert {:ok, stranded} =
             ControlPlane.enqueue_command(
               placement.id,
               "get_session",
               %{"session_ref" => session.id},
               "ryker:test:bound-placement-stranded-read"
             )

    # The worker stopped polling: its lease ran out with nothing delivered.
    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(Repo.now!(), -1, :second)]
    )

    # The first try retires the lapsed placement and fences what it still had
    # queued; the next addresses the existing runtime, and a busy holder needs
    # no new slot for it.
    assert {:error, {:coop_session_replacement_required, _, 1}} =
             ControlPlane.place_session(session.id, requirements, 60)

    assert {:ok, recovered} = ControlPlane.place_session(session.id, requirements, 60)
    assert recovered.generation == placement.generation + 1
    assert recovered.worker_id == placement.worker_id
    assert recovered.state == :active
    assert Repo.get!(Placement, placement.id).state == :replaced

    # The old placement's undelivered command is fenced, not carried onto the new generation.
    assert Repo.get!(Command, stranded.id).status == :failed

    # An UNBOUND session still fails closed: nothing proves a worker holds its material.
    authorize_and_poll!("worker-a")
    unbound = place!("unbound-placement-recovery")

    Repo.update_all(
      from(value in Placement, where: value.id == ^unbound.id),
      set: [lease_expires_at: DateTime.add(Repo.now!(), -1, :second)]
    )

    assert {:error, {:coop_session_replacement_required, _, 1}} =
             ControlPlane.place_session(unbound.session_id, requirements, 60)

    assert {:error, {:coop_session_replacement_required, _, 1}} =
             ControlPlane.place_session(unbound.session_id, requirements, 60)
  end

  test "a revoking placement cannot be replaced before its worker lease expires" do
    authorize_and_poll!("worker-a")
    placement = place!("revoking-placement")

    placement
    |> Ecto.Changeset.change(state: :revoking)
    |> Repo.update!()

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    assert {:error, {:coop_session_replacement_pending, session_id, generation, lease_expires_at}} =
             ControlPlane.place_session(placement.session_id, requirements, 60)

    assert session_id == placement.session_id
    assert generation == placement.generation
    assert lease_expires_at == placement.lease_expires_at
    assert Repo.get!(Placement, placement.id).state == :revoking
  end

  test "an expired fleet placement immediately revokes its episode state capability" do
    authorize_and_poll!("worker-a")
    session = session!("expired-state-capability")

    assert {:ok, claim} = Custody.claim_next("worker:state-capability", 60, :work)

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

    assert {:ok, binding} =
             StateBinding.derive(
               session,
               claim.turn,
               StateBinding.placement_scope(placement),
               "https://ryker.example/v1/state-tools/mcp",
               Ryker.Secret.new("state-tools-secret-for-tests")
             )

    assert {:ok, _turn} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               binding.endpoint,
               binding.token_sha256
             )

    assert {:ok, _resolved} = Binding.resolve(binding.token)

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(Repo.now!(), -1, :second)]
    )

    assert Binding.resolve(binding.token) == {:error, :state_tools_binding_not_authorized}
  end

  test "a replacement worker cannot inherit the previous placement state capability" do
    authorize_and_poll!("worker-a")
    authorize_and_poll!("worker-b")
    session = session!("replacement-state-capability")

    assert {:ok, claim} = Custody.claim_next("worker:state-capability", 60, :work)

    assert {:ok, first_placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: "ryker",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, binding} =
             StateBinding.derive(
               session,
               claim.turn,
               StateBinding.placement_scope(first_placement),
               "https://ryker.example/v1/state-tools/mcp",
               Ryker.Secret.new("state-tools-secret-for-tests")
             )

    assert {:ok, _turn} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               binding.endpoint,
               binding.token_sha256
             )

    assert {:ok, _resolved} = Binding.resolve(binding.token)

    first_placement
    |> Ecto.Changeset.change(state: :replaced)
    |> Repo.update!()

    replacement_id = Ecto.UUID.generate()

    %Placement{
      episode_id: first_placement.episode_id,
      generation: first_placement.generation + 1,
      id: replacement_id,
      last_acked_event_sequence: 0,
      lease_expires_at: DateTime.add(Repo.now!(), 60, :second),
      lease_ref: "placement-lease:#{replacement_id}",
      requirements: first_placement.requirements,
      requirements_fingerprint: first_placement.requirements_fingerprint,
      session_id: first_placement.session_id,
      state: :active,
      worker_id: "worker-b"
    }
    |> Repo.insert!()

    assert Binding.resolve(binding.token) == {:error, :state_tools_binding_not_authorized}
  end

  test "a clock-skewed worker cannot renew placement authority" do
    authorize_and_poll!("worker-a")
    placement = place!("clock-skew")
    before = placement.lease_expires_at

    skewed =
      poll("worker-a", "workspace-main", "poll:worker-a:clock-skew")
      |> put_in(["worker", "clock_at"], "2000-01-01T00:00:00Z")

    assert ControlPlane.handle_poll_certificate("worker-a", skewed) ==
             {:error, {:coop_worker_clock_skew, "worker-a"}}

    assert Repo.get!(Placement, placement.id).lease_expires_at == before
  end

  test "commands redeliver until acknowledgement and exact results reconcile once" do
    authorize_and_poll!("worker-a")
    placement = place!("command-redelivery")

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "submit_turn",
               turn_payload("turn-2"),
               "ryker:work:turn:turn-2:g1"
             )

    assert {:ok, first} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:command:1")
             )

    assert [delivered] = first["commands"]
    assert delivered["command_id"] == command.id
    assert delivered["placement_generation"] == placement.generation
    assert delivered["lease_ref"] == placement.lease_ref

    assert {:ok, repeated} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:command:2")
             )

    assert [same] = repeated["commands"]
    assert Map.drop(same, ["lease_expires_at"]) == Map.drop(delivered, ["lease_expires_at"])

    assert {:ok, repeated_expiry, 0} = DateTime.from_iso8601(same["lease_expires_at"])
    assert {:ok, delivered_expiry, 0} = DateTime.from_iso8601(delivered["lease_expires_at"])
    assert DateTime.compare(repeated_expiry, delivered_expiry) in [:eq, :gt]

    acknowledged =
      poll("worker-a", "workspace-main", "poll:worker-a:command:3",
        acknowledged_command_ids: [command.id]
      )

    assert {:ok, %{"commands" => [acknowledged_redelivery]}} =
             ControlPlane.handle_poll_certificate("worker-a", acknowledged)

    assert acknowledged_redelivery["command_id"] == command.id
    assert Repo.get!(Command, command.id).status == :acknowledged

    resource = %{
      "status" => 200,
      "body" => %{"session_id" => "coop-session-1", "turn_id" => "coop-turn-1"}
    }

    completed =
      poll("worker-a", "workspace-main", "poll:worker-a:command:4",
        command_results: [
          %{
            "command_id" => command.id,
            "error" => nil,
            "operation_key" => command.idempotency_key,
            "resource" => resource,
            "state" => "succeeded"
          }
        ]
      )

    assert {:ok, first_result_response} =
             ControlPlane.handle_poll_certificate("worker-a", completed)

    assert first_result_response["acknowledged_result_command_ids"] == [command.id]

    assert {:ok, replayed_result_response} =
             ControlPlane.handle_poll_certificate("worker-a", completed)

    assert replayed_result_response["acknowledged_result_command_ids"] == [command.id]

    settled = Repo.get!(Command, command.id)
    assert settled.status == :succeeded
    assert settled.result == resource

    changed =
      put_in(completed, ["command_results", Access.at(0), "resource", "body", "turn_id"], "wrong")

    command_id = command.id

    assert refused(fn -> ControlPlane.handle_poll_certificate("worker-a", changed) end) =~
             "{:coop_worker_command_result_conflict, #{inspect(command_id)}}"
  end

  # A result naming a response body Ryker never received rolled back the whole
  # poll: the worker's heartbeat, its other results and its deliveries failed on
  # every poll until the file existed, and a worker that had already reported
  # the result could not upload it again. That one command's outcome is unknown;
  # nothing else the worker reported is.
  test "a result whose body never arrived is uncertain and the rest of its poll commits" do
    authorize_and_poll!("worker-missing-body")
    placement = place!("missing-body")

    assert {:ok, missing} =
             ControlPlane.enqueue_command(
               placement.id,
               "api_request",
               %{"method" => "GET", "path" => "/v1/sessions/s/changes"},
               "missing-body:changes"
             )

    assert {:ok, other} =
             ControlPlane.enqueue_command(
               placement.id,
               "get_session",
               %{"coop_session_id" => "s"},
               "missing-body:session"
             )

    assert Enum.sort(delivered!("worker-missing-body", "missing-body:deliver")) ==
             Enum.sort([missing.id, other.id])

    bytes = String.duplicate("never uploaded ", 100)

    reference = %{
      "sha256" => digest(bytes),
      "byte_size" => byte_size(bytes)
    }

    results = [
      %{
        "command_id" => missing.id,
        "error" => nil,
        "operation_key" => missing.idempotency_key,
        "resource" => %{"status" => 200, "body_ref" => reference},
        "state" => "succeeded"
      },
      %{
        "command_id" => other.id,
        "error" => nil,
        "operation_key" => other.idempotency_key,
        "resource" => %{"status" => 200, "body" => %{"id" => "s"}},
        "state" => "succeeded"
      }
    ]

    old_expiry = DateTime.add(Repo.now!(), 1, :second)
    placement |> Ecto.Changeset.change(lease_expires_at: old_expiry) |> Repo.update!()
    body_root = body_root!()

    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               "worker-missing-body",
               poll("worker-missing-body", "workspace-main", "missing-body:results",
                 command_results: results
               ),
               body_root: body_root
             )

    assert response["acknowledged_result_command_ids"] == [missing.id, other.id]

    persisted = Repo.get!(Command, missing.id)
    assert persisted.status == :uncertain
    assert persisted.operation_key == missing.idempotency_key
    assert is_nil(persisted.result)

    assert persisted.error == %{
             "code" => "response_body_missing",
             "detail" => "the worker reported a response body Ryker never received",
             "status" => 409
           }

    assert Repo.get!(Command, other.id).status == :succeeded

    assert DateTime.compare(Repo.get!(Placement, placement.id).lease_expires_at, old_expiry) ==
             :gt

    # The worker reports it again until acknowledged; the same result is.
    assert {:ok, replay} =
             ControlPlane.handle_poll_certificate(
               "worker-missing-body",
               poll("worker-missing-body", "workspace-main", "missing-body:replay",
                 command_results: results
               ),
               body_root: body_root
             )

    assert replay["acknowledged_result_command_ids"] == [missing.id, other.id]
  end

  # A placement another placement replaced is fenced: its worker's late result
  # is kept as uncertain, never as the session's answer.
  test "a worker result cannot cross its replaced placement generation" do
    authorize_and_poll!("worker-a")
    placement = place!("expired-command-result")

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "submit_turn",
               turn_payload("turn-expired"),
               "ryker:work:turn:expired:g1"
             )

    assert {:ok, %{"commands" => [%{"command_id" => command_id}]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:expired-result:1")
             )

    assert command_id == command.id

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(Repo.now!(), -1, :second), state: :replaced]
    )

    result = %{
      "command_id" => command.id,
      "error" => nil,
      "operation_key" => command.idempotency_key,
      "resource" => %{
        "status" => 200,
        "body" => %{"session_id" => "coop-session-expired", "turn_id" => "coop-turn-expired"}
      },
      "state" => "succeeded"
    }

    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:expired-result:2",
                 command_results: [result]
               )
             )

    assert response["acknowledged_result_command_ids"] == [command_id]

    assert Repo.get!(Placement, placement.id).state == :replaced

    persisted = Repo.get!(Command, command.id)
    assert persisted.status == :uncertain
    assert persisted.operation_key == command.idempotency_key
    assert is_nil(persisted.result)

    assert persisted.error == %{
             "code" => "placement_not_authorized",
             "detail" => "worker result arrived after placement authority ended",
             "status" => 409
           }

    assert {:ok, replay} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:expired-result:3",
                 command_results: [result]
               )
             )

    assert replay["acknowledged_result_command_ids"] == [command.id]
  end

  # Every placement's lease ran out whenever Ryker itself was down for more
  # than one, for a deploy or a stalled Docker VM, and the worker's next poll
  # replaced them all: all work in flight was disrupted and every result that
  # came back was kept as uncertain (2026-10-04 review). Nothing took those
  # placements over, so they are the worker's again.
  test "a placement whose lease ran out while Ryker was away is the worker's again at its next poll" do
    authorize_and_poll!("worker-a")
    placement = place!("away-command-result")

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "submit_turn",
               turn_payload("turn-away"),
               "ryker:work:turn:away:g1"
             )

    assert {:ok, %{"commands" => [%{"command_id" => command_id}]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:away:1")
             )

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(Repo.now!(), -120, :second)]
    )

    result = %{
      "command_id" => command_id,
      "error" => nil,
      "operation_key" => command.idempotency_key,
      "resource" => %{
        "status" => 200,
        "body" => %{"session_id" => "coop-session-away", "turn_id" => "coop-turn-away"}
      },
      "state" => "succeeded"
    }

    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:away:2",
                 command_results: [result]
               )
             )

    assert response["acknowledged_result_command_ids"] == [command_id]

    renewed = Repo.get!(Placement, placement.id)
    assert renewed.state == :active
    assert DateTime.compare(renewed.lease_expires_at, Repo.now!()) == :gt
    refute Repo.get!(Command, command_id).status == :uncertain
  end

  # Only a poll by its own worker retired a placement, so a revoked worker's
  # and a vanished worker's stayed current until each session was placed
  # again, and readiness stayed red (2026-10-04 review).
  test "placements no worker will renew are retired, and a worker that may still poll keeps its own" do
    authorize_and_poll!("worker-a")
    vanished = place!("sweep-vanished")
    held = place!("sweep-held")
    now = Repo.now!()
    long_ago = DateTime.add(now, -20 * 60, :second)

    Repo.update_all(from(p in Placement, where: p.id == ^vanished.id),
      set: [lease_expires_at: long_ago]
    )

    Repo.update_all(from(w in Worker, where: w.id == "worker-a"), set: [last_seen_at: long_ago])

    authorize_and_poll!("worker-b")
    revoked = place!("sweep-revoked")
    assert revoked.worker_id == "worker-b"
    assert {:ok, _revoked} = WorkerLifecycle.revoke("worker-b", "operator:test")

    # Ryker itself has just started: a worker could not have polled it yet.
    assert {:ok, 1} =
             ControlPlane.retire_abandoned_placements(now, DateTime.add(now, -60, :second))

    assert Repo.get!(Placement, revoked.id).state == :replaced
    assert Repo.get!(Placement, vanished.id).state == :active

    assert {:ok, 1} =
             ControlPlane.retire_abandoned_placements(now, DateTime.add(now, -3_600, :second))

    assert Repo.get!(Placement, vanished.id).state == :replaced
    assert Repo.get!(Placement, held.id).state == :active
  end

  # The poll was one transaction, so one result Ryker refused refused the
  # whole poll: the worker sent it again and again, nothing else it reported
  # counted, and its leases ran out (2026-10-04 review).
  test "a refused result leaves the rest of the poll standing" do
    authorize_and_poll!("worker-a")
    placement = place!("poll-isolation")

    [good, bad] =
      for name <- ["good", "bad"] do
        assert {:ok, command} =
                 ControlPlane.enqueue_command(
                   placement.id,
                   "get_session",
                   %{"coop_session_id" => "coop-isolation"},
                   "ryker:test:poll-isolation:#{name}"
                 )

        command
      end

    assert {:ok, %{"commands" => [_one, _two]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:isolation:1")
             )

    result = fn command, key ->
      %{
        "command_id" => command.id,
        "error" => nil,
        "operation_key" => key,
        "resource" => %{"status" => 200, "body" => %{"session_id" => "coop-isolation"}},
        "state" => "succeeded"
      }
    end

    results = [result.(bad, "another-commands-key"), result.(good, good.idempotency_key)]

    log =
      capture_log(fn ->
        assert {:ok, response} =
                 ControlPlane.handle_poll_certificate(
                   "worker-a",
                   poll("worker-a", "workspace-main", "poll:worker-a:isolation:2",
                     command_results: results
                   )
                 )

        assert response["acknowledged_result_command_ids"] == [good.id]
      end)

    assert log =~ "result for command #{bad.id} refused"
    assert Repo.get!(Command, good.id).status == :succeeded
    assert is_nil(Repo.get!(Command, bad.id).operation_key)
  end

  test "a state bearer exists only in the response for its exact current placement" do
    secret = Ryker.Secret.new("fleet-state-binding-secret")
    endpoint = "https://ryker.example/v1/state-tools/mcp"

    authorize_and_poll!("worker-a")
    session = session!("state-binding-command")

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

    assert {:ok, claim} = Custody.claim_next("worker:state-binding-command", 60, :work)

    assert {:ok, binding} =
             StateBinding.derive(
               claim.session,
               claim.turn,
               StateBinding.placement_scope(placement),
               endpoint,
               secret
             )

    assert {:ok, _turn} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               endpoint,
               binding.token_sha256
             )

    descriptor = %{
      "endpoint" => endpoint,
      "token_sha256" => binding.token_sha256
    }

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "submit_turn",
               Map.put(turn_payload(claim.turn.turn_ref), "controller_tools", descriptor),
               "ryker:work:turn:state-binding:g1"
             )

    persisted = Repo.get!(Command, command.id)
    assert persisted.payload["controller_tools"] == descriptor
    refute inspect(persisted.payload) =~ binding.token

    assert {:ok, %{"commands" => [delivered]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:state-binding"),
               state_tools_secret: secret
             )

    assert delivered["payload"]["body"]["controller_tools"] == StateBinding.document(binding)
    refute Repo.get!(Command, command.id).payload["controller_tools"]["token"]
  end

  test "a Coop-sized frozen submission is durably enqueued without widening the command surface" do
    authorize_and_poll!("worker-a")
    placement = place!("large-frozen-submission")
    payload = %{"prompt" => String.duplicate("p", 200 * 1_024)}

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "validate_candidate",
               payload,
               "ryker:work:validation:large:g1"
             )

    assert command.payload == payload

    assert {:ok, _command} =
             ControlPlane.enqueue_command(
               placement.id,
               "fence_operation",
               %{"method" => "SubmitTurn", "request" => %{}},
               "ryker:work:fence:large:g1"
             )
  end

  test "event batches commit contiguously and exact replay never applies twice" do
    authorize_and_poll!("worker-a")
    placement = place!("ordered-events")

    batch = %{
      "after_sequence" => 0,
      "events" => [
        %{"kind" => "session", "payload" => %{"state" => "open"}, "sequence" => 1},
        %{"kind" => "turn", "payload" => %{"state" => "running"}, "sequence" => 2}
      ],
      "placement_generation" => placement.generation,
      "session_ref" => placement.session_id
    }

    event_poll =
      poll("worker-a", "workspace-main", "poll:worker-a:events:1", event_batches: [batch])

    assert {:ok, response} = ControlPlane.handle_poll_certificate("worker-a", event_poll)

    assert response["event_acknowledgements"] == [
             %{
               "placement_generation" => placement.generation,
               "sequence" => 2,
               "session_ref" => placement.session_id
             }
           ]

    assert Repo.aggregate(Event, :count) == 2
    assert Repo.get!(Placement, placement.id).last_acked_event_sequence == 2

    assert {:ok, replayed} = ControlPlane.handle_poll_certificate("worker-a", event_poll)
    assert replayed["event_acknowledgements"] == response["event_acknowledgements"]
    assert Repo.aggregate(Event, :count) == 2

    changed =
      put_in(
        event_poll,
        ["event_batches", Access.at(0), "events", Access.at(1), "payload", "state"],
        "completed"
      )

    assert refused(fn -> ControlPlane.handle_poll_certificate("worker-a", changed) end) =~
             "{:coop_worker_event_replay_conflict, 2}"
  end

  test "public Coop session events advance activity custody without retaining lifecycle payloads" do
    authorize_and_poll!("worker-a")
    placement = place!("session-activity")
    coop_session_id = "coop-session-activity"

    coarse_poll =
      poll("worker-a", "workspace-main", "poll:worker-a:coarse-before-session",
        event_batches: [
          %{
            "after_sequence" => 0,
            "events" => [
              %{"kind" => "session", "payload" => %{"state" => "open"}, "sequence" => 1}
            ],
            "placement_generation" => placement.generation,
            "session_ref" => placement.session_id
          }
        ]
      )

    assert {:ok, _response} = ControlPlane.handle_poll_certificate("worker-a", coarse_poll)

    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^placement.session_id),
        set: [coop_session_id: coop_session_id]
      )

    now = Repo.now!() |> DateTime.to_iso8601()

    session_event = fn sequence, id, type, payload ->
      %{
        "kind" => "session_event",
        "payload" => %{
          "id" => id,
          "occurred_at" => now,
          "payload" => payload,
          "sequence" => sequence,
          "session_id" => coop_session_id,
          "turn_id" => if(type == "session.created", do: nil, else: "turn-1"),
          "type" => type,
          "version" => 1
        },
        "sequence" => sequence
      }
    end

    batch = %{
      "after_sequence" => 0,
      "events" => [
        session_event.(1, "evt-session", "session.created", %{}),
        session_event.(2, "evt-tool", "tool.started", %{
          "title" => "Read repository",
          "tool_call_id" => "tool-1"
        })
      ],
      "placement_generation" => placement.generation,
      "session_ref" => placement.session_id
    }

    event_poll =
      poll("worker-a", "workspace-main", "poll:worker-a:session-activity", event_batches: [batch])

    assert {:ok, response} = ControlPlane.handle_poll_certificate("worker-a", event_poll)
    assert [%{"sequence" => 2}] = response["event_acknowledgements"]
    assert Repo.get!(Session, placement.session_id).activity_cursor == 0
    assert Repo.get!(Placement, placement.id).last_acked_session_event_sequence == 2
    assert Repo.get!(Placement, placement.id).last_acked_event_sequence == 1

    assert [%ActivityEvent{kind: "tool.started", remote_event_id: "evt-tool", sequence: 2}] =
             Repo.all(ActivityEvent)

    assert [%Event{payload: %{}, payload_fingerprint: fingerprint}] =
             Repo.all(
               from(event in Event, where: event.kind == "session_event" and event.sequence == 2)
             )

    assert byte_size(fingerprint) == 64

    assert {:ok, _replayed} = ControlPlane.handle_poll_certificate("worker-a", event_poll)
    assert Repo.aggregate(ActivityEvent, :count) == 1
  end

  test "redacted model progress cannot wedge the worker heartbeat" do
    authorize_and_poll!("worker-a")
    placement = place!("redacted-model-progress")
    coop_session_id = "coop-redacted-model-progress"

    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^placement.session_id),
        set: [coop_session_id: coop_session_id]
      )

    now = Repo.now!() |> DateTime.to_iso8601()

    session_event = fn sequence, id, type, payload ->
      %{
        "kind" => "session_event",
        "payload" => %{
          "id" => id,
          "occurred_at" => now,
          "payload" => payload,
          "sequence" => sequence,
          "session_id" => coop_session_id,
          "turn_id" => "turn-redacted-progress",
          "type" => type,
          "version" => 1
        },
        "sequence" => sequence
      }
    end

    batch = %{
      "after_sequence" => 0,
      "events" => [
        session_event.(1, "evt-session", "session.created", %{}),
        session_event.(2, "evt-progress", "model.progress", %{})
      ],
      "placement_generation" => placement.generation,
      "session_ref" => placement.session_id
    }

    # Covers the production worker redacting progress text from two active runs;
    # one rejected event then returned HTTP 400 for every heartbeat and stopped all work.
    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:redacted-progress",
                 event_batches: [batch]
               )
             )

    assert [%{"sequence" => 2}] = response["event_acknowledgements"]

    assert [%ActivityEvent{kind: "model.progress", payload: %{"evidence_version" => 1}}] =
             Repo.all(ActivityEvent)
  end

  test "session creation activity cannot wedge the worker before asynchronous create binding" do
    authorize_and_poll!("worker-a")
    placement = place!("pre-bind-session-created")
    coop_session_id = "coop-session-created-before-binding"
    now = Repo.now!() |> DateTime.to_iso8601()

    created = %{
      "kind" => "session_event",
      "payload" => %{
        "id" => "evt-session-created",
        "occurred_at" => now,
        "sequence" => 1,
        "session_id" => coop_session_id,
        "turn_id" => nil,
        "type" => "session.created",
        "version" => 1
      },
      "sequence" => 1
    }

    batch = %{
      "after_sequence" => 0,
      "events" => [created],
      "placement_generation" => placement.generation,
      "session_ref" => placement.session_id
    }

    # A real asynchronous create emitted this lifecycle event before Work could
    # bind its session id. Every later worker heartbeat then failed with HTTP 400.
    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:pre-bind-created",
                 event_batches: [batch]
               )
             )

    assert response["event_acknowledgements"] == [
             %{
               "placement_generation" => placement.generation,
               "sequence" => 1,
               "session_ref" => placement.session_id
             }
           ]

    assert Repo.get!(Session, placement.session_id).coop_session_id == nil
    assert Repo.get!(Placement, placement.id).last_acked_session_event_sequence == 1
    assert Repo.aggregate(ActivityEvent, :count) == 0

    assert [%Event{kind: "session_event", sequence: 1}] = Repo.all(Event)

    # This acknowledged session-event cursor is independent from the coarse
    # event cursor; conflating them left the whole service falsely unready.
    assert {:ok, %{event_cursor_lag: 0}} = Observability.fleet()

    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^placement.session_id),
        set: [coop_session_id: coop_session_id]
      )

    assert {:ok, replay} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:post-bind-replay",
                 event_batches: [batch]
               )
             )

    assert [%{"sequence" => 1}] = replay["event_acknowledgements"]

    activity = %{
      "kind" => "session_event",
      "payload" => %{
        "id" => "evt-tool-after-binding",
        "occurred_at" => now,
        "payload" => %{"kind" => "read", "tool_call_id" => "tool-after-binding"},
        "sequence" => 2,
        "session_id" => coop_session_id,
        "turn_id" => "turn-after-binding",
        "type" => "tool.started",
        "version" => 1
      },
      "sequence" => 2
    }

    assert {:ok, continued} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:post-bind-activity",
                 event_batches: [%{batch | "after_sequence" => 1, "events" => [activity]}]
               )
             )

    assert [%{"sequence" => 2}] = continued["event_acknowledgements"]

    assert [%ActivityEvent{kind: "tool.started", sequence: 2}] = Repo.all(ActivityEvent)
  end

  test "workspace binding activity cannot wedge the worker before asynchronous session binding" do
    authorize_and_poll!("worker-a")
    placement = place!("pre-bind-workspace-task")
    coop_session_id = "coop-session-task-bound-before-binding"

    workspace_task = %{
      "authority_limits" => ["runner version only"],
      "offer_ref" => "record:task_offer:pre-bind-workspace-task",
      "prompt" => "Bump the internal hosted runner version.",
      "source_refs" => [],
      "success_checks" => ["focused checks pass"],
      "title" => "Bump hosted runner"
    }

    placement.session_id
    |> then(&Repo.get!(Session, &1))
    |> Session.Changeset.bind_workspace_task(workspace_task)
    |> Repo.update!()

    now = Repo.now!() |> DateTime.to_iso8601()

    created = %{
      "kind" => "session_event",
      "payload" => %{
        "id" => "evt-pre-bind-session-created",
        "occurred_at" => now,
        "sequence" => 1,
        "session_id" => coop_session_id,
        "turn_id" => nil,
        "type" => "session.created",
        "version" => 1
      },
      "sequence" => 1
    }

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:pre-bind-task-created",
                 event_batches: [
                   %{
                     "after_sequence" => 0,
                     "events" => [created],
                     "placement_generation" => placement.generation,
                     "session_ref" => placement.session_id
                   }
                 ]
               )
             )

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "ensure_workspace",
               %{
                 "coop_session_id" => coop_session_id,
                 "expected_revision" => 1,
                 "task" => workspace_task
               },
               "ryker:workspace:pre-bind-task"
             )

    assert {:ok, %{"commands" => [%{"command_id" => command_id}]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:pre-bind-task-deliver")
             )

    assert command_id == command.id

    bound_task = %{
      "draft_sha256" => String.duplicate("a", 64),
      "id" => "ryker-pre-bind-task",
      "offer_ref" => workspace_task["offer_ref"],
      "queue_id" => String.duplicate("b", 32),
      "task_id" => String.duplicate("c", 32)
    }

    task_bound = %{
      "kind" => "session_event",
      "payload" => %{
        "id" => "evt-pre-bind-workspace-task",
        "occurred_at" => now,
        "sequence" => 2,
        "session_id" => coop_session_id,
        "turn_id" => nil,
        "type" => "workspace.task_bound",
        "version" => 1
      },
      "sequence" => 2
    }

    unproven_event_poll =
      poll("worker-a", "workspace-main", "poll:worker-a:unproven-pre-bind-task-event",
        event_batches: [
          %{
            "after_sequence" => 1,
            "events" => [task_bound],
            "placement_generation" => placement.generation,
            "session_ref" => placement.session_id
          }
        ]
      )

    assert refused(fn ->
             ControlPlane.handle_poll_certificate("worker-a", unproven_event_poll)
           end) =~
             "{:coop_activity_session_conflict, #{inspect(coop_session_id)}}"

    remote = %{
      "id" => coop_session_id,
      "revision" => 2,
      "state" => "open",
      "workspace_task" => bound_task
    }

    assert {:ok, %{"acknowledged_result_command_ids" => [^command_id]}} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:pre-bind-task-result",
                 command_results: [
                   %{
                     "command_id" => command.id,
                     "error" => nil,
                     "operation_key" => command.idempotency_key,
                     "resource" => %{"status" => 200, "body" => %{"session" => remote}},
                     "state" => "succeeded"
                   }
                 ]
               )
             )

    placement
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(Repo.now!(), -1, :second))
    |> Repo.update!()

    # The third live retry bound the exact task, but its lifecycle event arrived before the
    # local session ID was stored and outlived its short placement lease. Rejecting that event
    # returned HTTP 400 on every later poll.
    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:pre-bind-task-event",
                 event_batches: [
                   %{
                     "after_sequence" => 1,
                     "events" => [task_bound],
                     "placement_generation" => placement.generation,
                     "session_ref" => placement.session_id
                   }
                 ]
               )
             )

    assert [%{"sequence" => 2}] = response["event_acknowledgements"]
    assert Repo.get!(Placement, placement.id).last_acked_session_event_sequence == 2
  end

  test "fresh worker events require current placement authority but exact replay remains acknowledged" do
    authorize_and_poll!("worker-a")
    placement = place!("event-authority")

    batch = %{
      "after_sequence" => 0,
      "events" => [%{"kind" => "turn", "payload" => %{"state" => "running"}, "sequence" => 1}],
      "placement_generation" => placement.generation,
      "session_ref" => placement.session_id
    }

    first =
      poll("worker-a", "workspace-main", "poll:worker-a:event-authority:1",
        event_batches: [batch]
      )

    assert {:ok, _response} = ControlPlane.handle_poll_certificate("worker-a", first)

    placement |> Ecto.Changeset.change(state: :revoking) |> Repo.update!()

    replay =
      poll("worker-a", "workspace-main", "poll:worker-a:event-authority:2",
        event_batches: [batch]
      )

    assert {:ok, _response} = ControlPlane.handle_poll_certificate("worker-a", replay)

    fresh =
      batch
      |> Map.put("after_sequence", 1)
      |> Map.put("events", [
        %{"kind" => "turn", "payload" => %{"state" => "completed"}, "sequence" => 2}
      ])

    rejected =
      poll("worker-a", "workspace-main", "poll:worker-a:event-authority:3",
        event_batches: [fresh]
      )

    placement_id = placement.id

    assert refused(fn -> ControlPlane.handle_poll_certificate("worker-a", rejected) end) =~
             "{:coop_worker_event_placement_not_authorized, #{inspect(placement_id)}}"
  end

  test "a replaced placement can finish publishing its bound public session activity" do
    authorize_and_poll!("worker-a")
    placement = place!("late-bound-activity")
    coop_session_id = "coop-late-bound-activity"

    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^placement.session_id),
        set: [coop_session_id: coop_session_id]
      )

    expired_at = Repo.now!() |> DateTime.add(-5, :second)

    # Its lease ran out and recovery replaced it; the worker still holds the
    # session and sends what it had.
    placement
    |> Ecto.Changeset.change(lease_expires_at: expired_at, state: :replaced)
    |> Repo.update!()

    event = %{
      "kind" => "session_event",
      "payload" => %{
        "id" => "evt-late-progress",
        "occurred_at" => Repo.now!() |> DateTime.to_iso8601(),
        "payload" => %{},
        "sequence" => 1,
        "session_id" => coop_session_id,
        "turn_id" => "turn-late-progress",
        "type" => "model.progress",
        "version" => 1
      },
      "sequence" => 1
    }

    batch = %{
      "after_sequence" => 0,
      "events" => [event],
      "placement_generation" => placement.generation,
      "session_ref" => placement.session_id
    }

    # The two repaired Slack runs completed locally but their activity backlog
    # arrived after the one-minute lease; rejecting it wedged every later heartbeat.
    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:late-bound-activity",
                 event_batches: [batch]
               )
             )

    assert [%{"sequence" => 1}] = response["event_acknowledgements"]
    assert Repo.get!(Placement, placement.id).state == :replaced

    assert [%ActivityEvent{kind: "model.progress", remote_event_id: "evt-late-progress"}] =
             Repo.all(ActivityEvent)
  end

  test "a replaced placement acknowledges only its exact terminal workspace discard" do
    authorize_and_poll!("worker-a")
    placement = place!("terminal-discard-after-replacement")
    coop_session_id = "coop-terminal-discard-after-replacement"

    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^placement.session_id),
        set: [coop_session_id: coop_session_id]
      )

    placement |> Ecto.Changeset.change(state: :replaced) |> Repo.update!()

    discarded = %{
      "kind" => "session_event",
      "payload" => %{
        "id" => "evt-workspace-discarded",
        "occurred_at" => Repo.now!() |> DateTime.to_iso8601(),
        "sequence" => 1,
        "session_id" => coop_session_id,
        "type" => "workspace.discarded",
        "version" => 1
      },
      "sequence" => 1
    }

    terminal_poll =
      poll("worker-a", "workspace-main", "poll:worker-a:terminal-discard",
        event_batches: [
          %{
            "after_sequence" => 0,
            "events" => [discarded],
            "placement_generation" => placement.generation,
            "session_ref" => placement.session_id
          }
        ]
      )

    wrong_session =
      put_in(
        terminal_poll,
        ["event_batches", Access.at(0), "events", Access.at(0), "payload", "session_id"],
        "coop-session-owned-by-someone-else"
      )

    assert refused(fn -> ControlPlane.handle_poll_certificate("worker-a", wrong_session) end) =~
             "coop_worker_event_placement_not_authorized"

    # One discarded workspace event blocked every later heartbeat in production,
    # taking the only editing worker and the whole service out of readiness.
    assert {:ok, response} = ControlPlane.handle_poll_certificate("worker-a", terminal_poll)

    assert response["event_acknowledgements"] == [
             %{
               "placement_generation" => placement.generation,
               "sequence" => 1,
               "session_ref" => placement.session_id
             }
           ]

    assert Repo.get!(Placement, placement.id).last_acked_session_event_sequence == 1
    assert [%Event{kind: "session_event", sequence: 1}] = Repo.all(Event)
    assert Repo.aggregate(ActivityEvent, :count) == 0
  end

  test "a session can only be told to resume where a worker could actually take it" do
    # The learning lane sat unplaceable for twelve hours in 2026-09-11 because a
    # worker advertised no digest for its policy, and every surface still said
    # the work was fine. A recovery surface that offers to resume work no worker
    # can accept repeats that, this time in front of an operator.
    session = session!("resume-capability")

    requirements = %{
      capability_names: ["controller-tools"],
      capability_versions: %{},
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    refute ControlPlane.worker_available?(session, requirements)

    authorize_and_poll!("worker-resume")
    assert ControlPlane.worker_available?(session, requirements)

    # Each half of eligibility withdraws the offer on its own.
    assert ControlPlane.worker_available?(session, %{requirements | repository_ref: "other"})

    refute ControlPlane.worker_available?(session, %{
             requirements
             | capability_names: ["controller-tools", "unbuilt"]
           })

    refute ControlPlane.worker_available?(session, %{requirements | workspace_ref: "workspace-b"})

    authorize_and_poll!("worker-resume", capacity: capacity(0, 4))
    refute ControlPlane.worker_available?(session, requirements)

    authorize_and_poll!("worker-resume")
    assert ControlPlane.worker_available?(session, requirements)

    Repo.update_all(from(worker in Worker, where: worker.id == "worker-resume"),
      set: [capabilities: []]
    )

    refute ControlPlane.worker_available?(session, requirements)
  end

  test "a learning attempt asks the fleet whether a worker would take its session first" do
    # Learning spent a start on every attempt while no worker could take its
    # session, then needed a person after three, having asked no model
    # anything. It now asks first, and must hear the answer placement gives.
    {:ok, client} =
      Client.new(
        capability_names: ["controller-tools"],
        workspace_ref: "workspace-main"
      )

    learning = %Session{
      execution_kind: :learning,
      policy: "work-read-only",
      policy_digest: @policy_digest
    }

    refute Client.accepts_session?(client, learning)

    authorize_and_poll!("worker-learning")
    assert Client.accepts_session?(client, learning)

    assert Client.accepts_session?(client, %{
             learning
             | policy_digest: String.duplicate("e", 64)
           })

    authorize_and_poll!("worker-learning", capacity: capacity(0, 4))
    refute Client.accepts_session?(client, learning)
  end

  test "work is portable only when the host holds a snapshot of the source it is pinned to" do
    # `blocked-task-recovery.md` state 2: a recovery surface may offer to resume
    # somewhere else only when a suitable worker AND a verified portable
    # snapshot exist. Offering it without the snapshot promises continuity the
    # host cannot deliver; the operator would lose the working copy instead.
    session = session!("portable-workspace")
    authorize_and_poll!("worker-portable")

    requirements = %{
      capability_names: ["controller-tools"],
      capability_versions: %{},
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    body_root = body_root!()
    assert ControlPlane.portable_workspace(session, requirements, body_root) == nil

    command = checkpoint_command!(session)
    transfer!(command, session, "checkpoint:portable", body_root)

    assert ControlPlane.portable_workspace(session, requirements, body_root) == %{
             byte_size: 4_096,
             checkpoint_ref: "checkpoint:portable",
             repository_ref: "ryker"
           }

    # A checkpoint carries the exact tree of the source it was taken from, so a
    # replacement pinned to a different source may never be seeded from it.
    moved =
      Repo.insert!(
        Session.Changeset.insert(
          Ecto.UUID.generate(),
          session.episode_id,
          2,
          session.policy,
          session.policy_digest,
          session.repository_ref,
          "resume-moved",
          %{
            authority_digest: session.authority_digest,
            repository_source: %{"kind" => "branch", "name" => "feature/other"},
            workspace_task: nil
          }
        )
      )

    assert ControlPlane.portable_workspace(moved, requirements, body_root) == nil
  end

  test "repository-free chat work has no portable workspace" do
    # Clean-install Chat is intentionally useful before a repository is
    # imported. Its failure recovery page must not turn a nil repository into
    # an unsafe Ecto comparison and crash while trying to find a checkpoint.
    session = session!("portable-conversation")

    Repo.update_all(from(s in Session, where: s.id == ^session.id),
      set: [repository_ref: nil, repository_source: nil]
    )

    session = Repo.get!(Session, session.id)
    authorize_and_poll!("worker-portable-conversation")

    requirements = %{
      capability_names: ["controller-tools"],
      capability_versions: %{},
      repository_ref: nil,
      workspace_ref: "workspace-main"
    }

    assert ControlPlane.worker_available?(session, requirements)
    assert ControlPlane.portable_workspace(session, requirements, body_root!()) == nil
  end

  # A poll applies what it can. An item Ryker refuses is left unacknowledged,
  # so the worker sends it again, and logged; the poll itself still answers.
  defp refused(poll) do
    capture_log(fn ->
      assert {:ok, response} = poll.()
      assert response["acknowledged_result_command_ids"] == []
      assert response["event_acknowledgements"] == []
    end)
  end

  defp authorize_and_poll!(worker_id, options \\ []) do
    assert {:ok, _worker} =
             CoopWorkers.authorize(
               worker_id,
               "workspace-main",
               certificate_digest(worker_id)
             )

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               worker_id,
               poll(worker_id, "workspace-main", "poll:#{worker_id}:hello", options)
             )
  end

  defp certificate_digest(value),
    do: digest(value)

  defp idle_poll!(worker_id, suffix, capacity) do
    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               worker_id,
               poll(worker_id, "workspace-main", "poll:#{worker_id}:#{suffix}",
                 capacity: capacity
               )
             )
  end

  defp bind!(session, coop_session_id),
    do: session |> Ecto.Changeset.change(coop_session_id: coop_session_id) |> Repo.update!()

  defp delivered!(worker_id, suffix) do
    assert {:ok, %{"commands" => commands}} =
             ControlPlane.handle_poll_certificate(
               worker_id,
               poll(worker_id, "workspace-main", "poll:#{worker_id}:#{suffix}",
                 capacity: capacity(4, 4)
               )
             )

    Enum.map(commands, & &1["command_id"])
  end

  defp place!(suffix) do
    session = session!(suffix)

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

    placement
  end

  test "a worker that refuses allocation stops taking new forks and says why" do
    # A worker whose protected forks filled its budget kept being handed new
    # sessions, which then failed on its filesystem instead of being placed
    # somewhere with room, and the operator saw a generic capacity error.
    authorize_and_poll!("worker-full",
      storage: storage(allocation: "refused", refusal_reason: "reserve_exhausted")
    )

    session = session!("storage-refused")

    requirements = %{
      capability_names: ["controller-tools"],
      repository_ref: "ryker",
      workspace_ref: "workspace-main"
    }

    assert ControlPlane.place_session(session.id, requirements, 60) ==
             {:error, {:coop_worker_storage_refused, session.id, "reserve_exhausted"}}

    worker = Repo.get!(Worker, "worker-full")
    assert worker.storage["allocation"] == "refused"
    assert worker.storage["disposable_bytes"] == 9_663_676_416
    assert worker.storage["measured_at"] == "2026-09-11T09:30:00Z"

    # Control, cleanup and existing work keep running on the refused worker.
    workspace_free = session!("storage-refused-workspace-free", nil)

    assert {:ok, placement} =
             ControlPlane.place_session(
               workspace_free.id,
               %{requirements | repository_ref: nil},
               60
             )

    assert placement.worker_id == "worker-full"

    # The worker's own return to `open` is the only recovery signal.
    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-full",
               poll("worker-full", "workspace-main", "poll:worker-full:2",
                 storage: storage(allocation: "open", refusal_reason: nil)
               )
             )

    assert {:ok, recovered} = ControlPlane.place_session(session.id, requirements, 60)
    assert recovered.worker_id == "worker-full"
  end

  test "reported storage is measured, never estimated, and reclamation only counts a fall" do
    authorize_and_poll!("worker-measured", storage: storage(disposable_bytes: 9_663_676_416))

    assert Repo.get!(Worker, "worker-measured").storage_reclaimed_bytes == 0

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-measured",
               poll("worker-measured", "workspace-main", "poll:worker-measured:2",
                 storage: storage(disposable_bytes: 1_073_741_824)
               )
             )

    reclaimed = Repo.get!(Worker, "worker-measured")
    assert reclaimed.storage_reclaimed_bytes == 8_589_934_592

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-measured",
               poll("worker-measured", "workspace-main", "poll:worker-measured:3",
                 storage: storage(disposable_bytes: 5_368_709_120)
               )
             )

    assert Repo.get!(Worker, "worker-measured").storage_reclaimed_bytes == 8_589_934_592

    # An older worker reports nothing. Unknown is not zero and is not reclamation.
    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               "worker-measured",
               poll("worker-measured", "workspace-main", "poll:worker-measured:4")
             )

    unknown = Repo.get!(Worker, "worker-measured")
    assert is_nil(unknown.storage)
    assert unknown.storage_reclaimed_bytes == 8_589_934_592
  end

  defp session!(suffix, repository_ref \\ "ryker") do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "fleet:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: Repo.now!(),
        turn_ref: "turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             WorkSessions.pin_episode(command.episode_id, "work-read-only", @policy_digest,
               authority_digest: @authority_digest,
               repository_ref: repository_ref
             )

    WorkerJob.pin!(session)
  end

  defp poll(worker_id, workspace_ref, poll_ref, options \\ []) do
    %{
      "acknowledged_command_ids" => Keyword.get(options, :acknowledged_command_ids, []),
      "command_results" => Keyword.get(options, :command_results, []),
      "event_batches" => Keyword.get(options, :event_batches, []),
      "poll_ref" => poll_ref,
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-abc123",
        "capabilities" =>
          Keyword.get(options, :capabilities, [
            %{"name" => "controller-tools", "version" => "1"}
          ]),
        "capacity" => Keyword.get(options, :capacity, capacity(2, 4)),
        "clock_at" => DateTime.to_iso8601(Repo.now!()),
        "id" => worker_id,
        "protocol_version" => "2",
        "sandbox_digest" => @sandbox_digest,
        "state" => "eligible",
        "storage" => Keyword.get(options, :storage),
        "workspace_ref" => workspace_ref
      }
    }
  end

  defp storage(overrides) do
    %{
      "allocation" => Keyword.get(overrides, :allocation, "open"),
      "capacity_bytes" => 536_870_912_000,
      "disposable_bytes" => Keyword.get(overrides, :disposable_bytes, 9_663_676_416),
      "free_bytes" => 4_294_967_296,
      "high_watermark_bytes" => 64_424_509_440,
      "low_watermark_bytes" => 48_318_382_080,
      "measured_at" => "2026-09-11T09:30:00Z",
      "protected_bytes" => 21_474_836_480,
      "refusal_reason" => Keyword.get(overrides, :refusal_reason),
      "reserve_bytes" => 5_368_709_120,
      "unattributed_bytes" => 1_073_741_824,
      "version" => 1
    }
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

  defp turn_payload(ref) do
    %{
      "coop_session_id" => "s",
      "expected_revision" => 1,
      "turn_ref" => ref,
      "submission_sha256" => String.duplicate("c", 64),
      "submission" => %{
        "prompt" => "Continue",
        "input_artifact_refs" => [],
        "output_schema" => %{"type" => "object"}
      }
    }
  end

  defp checkpoint_command!(session) do
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
               "checkpoint_workspace",
               %{
                 "coop_session_id" => "remote:#{session.id}",
                 "expected_revision" => 2,
                 "repository_ref" => session.repository_ref,
                 "session_ref" => session.id
               },
               "checkpoint:#{session.id}"
             )

    Repo.update!(
      Ecto.Changeset.change(command,
        completed_at: Repo.now!(),
        operation_key: command.idempotency_key,
        result: %{"status" => 200, "body" => %{"state" => "stored"}},
        result_fingerprint: String.duplicate("d", 64),
        status: :succeeded
      )
    )
  end

  # A checkpoint as Ryker keeps one: its bundle an encrypted file stored under
  # the command that brought it.
  defp transfer!(command, session, checkpoint_ref, body_root) do
    bundle = :binary.copy(<<3>>, 4_096)
    sha256 = digest(bundle)
    reference = %{"sha256" => sha256, "byte_size" => byte_size(bundle)}
    key = Ryker.Secret.new(:binary.copy(<<9>>, 32))
    assert :ok = Bodies.put(body_root, command.id, :response, reference, [bundle], key)

    Repo.insert!(%WorkspaceCheckpointTransfer{
      id: Ecto.UUID.generate(),
      body_command_id: command.id,
      bundle_byte_size: byte_size(bundle),
      bundle_sha256: sha256,
      checkpoint_ref: checkpoint_ref,
      command_id: command.id,
      descriptor: %{"version" => 2, "checkpoint_ref" => checkpoint_ref},
      encryption_key_sha256: digest(Ryker.Secret.reveal(key)),
      placement_generation: command.placement_generation,
      repository_ref: session.repository_ref,
      session_ref: session.id,
      worker_id: command.worker_id
    })
  end

  defp body_root! do
    root =
      Path.join(System.tmp_dir!(), "ryker-fleet-bodies-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
