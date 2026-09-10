defmodule Responder.CoopFleet.ControlPlaneTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Admission.FleetSession
  alias Responder.CoopFleet.{Command, ControlPlane, Event, Placement, Worker}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Observability
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.StateTools.Binding
  alias Responder.Work.{ActivityEvent, Custody, Session, SessionChangeset, StateBinding}
  alias Responder.Work.{Cancellation, TurnChangeset}

  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  test "an authenticated heartbeat records only the enrolled worker identity and coarse authority" do
    certificate = "worker-a-client-certificate"

    assert {:ok, enrolled} =
             ControlPlane.authorize_worker(
               "worker-a",
               "workspace-main",
               certificate_digest(certificate)
             )

    assert enrolled.state == :offline

    poll = poll("worker-a", "workspace-main", "poll:worker-a:1")

    assert {:ok, response} = ControlPlane.handle_poll("worker-a", poll)
    assert response["poll_ref"] == "poll:worker-a:1"
    assert response["commands"] == []

    worker = Repo.get!(Worker, "worker-a")
    assert worker.workspace_ref == "workspace-main"
    assert worker.state == :eligible
    assert worker.policy_digests == %{"work-read-only" => @policy_digest}
    assert worker.policy_authority_digests == %{"work-read-only" => @authority_digest}
    assert worker.repositories == [%{"ref" => "responder", "revision" => "commit:abc123"}]
    assert worker.capabilities == [%{"name" => "responder-state", "version" => "1"}]
    assert worker.capacity["turn_slots_free"] == 2
    assert worker.last_seen_at != nil

    assert {:ok, certificate_response} =
             ControlPlane.handle_poll_certificate(certificate, poll)

    assert certificate_response["poll_ref"] == "poll:worker-a:1"

    assert ControlPlane.handle_poll_certificate("wrong-certificate", poll) ==
             {:error, :coop_worker_certificate_not_authorized}

    assert ControlPlane.handle_poll("worker-b", poll) ==
             {:error, {:coop_worker_identity_mismatch, "worker-b", "worker-a"}}

    wrong_workspace = put_in(poll, ["worker", "workspace_ref"], "workspace-other")

    assert ControlPlane.handle_poll("worker-a", wrong_workspace) ==
             {:error, {:coop_worker_workspace_mismatch, "workspace-main", "workspace-other"}}
  end

  test "placement applies hard authority constraints and remains sticky" do
    authorize_and_poll!("worker-b", capacity: capacity(1, 4), repositories: ["other"])
    authorize_and_poll!("worker-a", capacity: capacity(2, 4))
    session = session!("sticky-placement")

    requirements = %{
      capability_names: ["responder-state"],
      repository_ref: "responder",
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
        %{"name" => "responder-state", "version" => "1"},
        %{"name" => "repository-freshness", "version" => "2"}
      ],
      capacity: capacity(2, 4)
    )

    session = session!("versioned-placement")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
                 capability_versions: %{"repository-freshness" => "2"},
                 repository_ref: "responder",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert placement.worker_id == "worker-freshness-v2"

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               "worker-freshness-v2",
               poll(
                 "worker-freshness-v2",
                 "workspace-main",
                 "poll:worker-freshness-v2:daemon-regressed"
               )
             )

    assert Repo.get!(Placement, placement.id).state == :revoking
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
               occurred_at: database_now!(),
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE4A6CC529D81"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, session} =
             FleetSession.ensure(entry, %{name: "work-read-only", digest: @policy_digest})

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
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
      capability_names: ["responder-state"],
      repository_ref: "responder",
      workspace_ref: "workspace-main"
    }

    assert {:ok, first_placement} = ControlPlane.place_session(first.id, requirements, 60)
    assert first_placement.worker_id == "worker-a"

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:one-free",
                 capacity: capacity(1, 4)
               )
             )

    second = session!("free-capacity-second")
    assert {:ok, second_placement} = ControlPlane.place_session(second.id, requirements, 60)
    assert second_placement.worker_id == "worker-a"
  end

  test "placement reservations and leases use the same database clock" do
    # Host/database clock drift made freshly reported capacity count an existing
    # placement twice, blocking the next conversation even with a free worker slot.
    authorize_and_poll!("worker-a")
    session = session!("reservation-database-clock")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{repository_ref: "responder", workspace_ref: "workspace-main"},
               60
             )

    assert placement.inserted_at == DateTime.add(placement.lease_expires_at, -60, :second)
  end

  test "fresh worker capacity can reuse slots held only by reflected parked placements" do
    # Two parked live sessions filled the placement ledger while the worker reported both
    # slots free, blocking every later Slack conversation before it could start.
    authorize_and_poll!("worker-a", capacity: capacity(2, 2))

    requirements = %{
      capability_names: ["responder-state"],
      repository_ref: "responder",
      workspace_ref: "workspace-main"
    }

    first = session!("reflected-capacity-first")
    assert {:ok, _placement} = ControlPlane.place_session(first.id, requirements, 60)

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:first-reflected",
                 capacity: capacity(1, 2)
               )
             )

    second = session!("reflected-capacity-second")
    assert {:ok, _placement} = ControlPlane.place_session(second.id, requirements, 60)

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:both-parked",
                 capacity: capacity(2, 2)
               )
             )

    next = session!("capacity-after-reflected-placements")
    assert {:ok, placement} = ControlPlane.place_session(next.id, requirements, 60)
    assert placement.worker_id == "worker-a"
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
               %{"session_id" => "coop-closed-placement-capacity"},
               "responder:test:closed-placement-capacity"
             )

    assert {:ok, %{"commands" => [%{"command_id" => command_id}]}} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:close-capacity:deliver",
                 capacity: capacity(0, 1)
               )
             )

    assert command_id == command.id

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:close-capacity:complete",
                 capacity: capacity(1, 1),
                 command_results: [
                   %{
                     "command_id" => command.id,
                     "error" => nil,
                     "operation_key" => command.idempotency_key,
                     "resource" => %{
                       "session_id" => "coop-closed-placement-capacity",
                       "state" => "closed"
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
                 capability_names: ["responder-state"],
                 repository_ref: "responder",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert next_placement.worker_id == "worker-a"
  end

  test "authority drift revokes placement renewal before another command is delivered" do
    authorize_and_poll!("worker-a")
    placement = place!("authority-drift")

    assert placement.requirements == %{
             "capability_names" => ["responder-state"],
             "capability_versions" => %{},
             "authority_digest" => @authority_digest,
             "policy" => "work-read-only",
             "policy_digest" => @policy_digest,
             "repository_ref" => "responder",
             "sandbox_digest" => @sandbox_digest,
             "workspace_ref" => "workspace-main"
           }

    assert {:ok, _command} =
             ControlPlane.enqueue_command(
               placement.id,
               "create_session",
               %{"external_ref" => "episode-authority-drift"},
               "responder:work:create:authority-drift:g1"
             )

    changed =
      poll("worker-a", "workspace-main", "poll:worker-a:authority-drift")
      |> put_in(
        ["worker", "policy_authority_digests", "work-read-only"],
        String.duplicate("e", 64)
      )

    assert {:ok, %{"commands" => []}} = ControlPlane.handle_poll("worker-a", changed)
    assert Repo.get!(Placement, placement.id).state == :revoking

    assert Repo.get_by!(Command, idempotency_key: "responder:work:create:authority-drift:g1").status ==
             :queued
  end

  test "a matching policy digest cannot place work on wider execution authority" do
    authorize_and_poll!("worker-wide",
      authority_digest: String.duplicate("e", 64),
      capacity: capacity(4, 4)
    )

    authorize_and_poll!("worker-exact", capacity: capacity(1, 4))
    session = session!("authority-equivalence")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
                 repository_ref: "responder",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert placement.worker_id == "worker-exact"
  end

  test "an expired placement is terminalized and requires a new immutable Work session" do
    authorize_and_poll!("worker-a")
    placement = place!("expired-placement")

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "get_session",
               %{"session_ref" => placement.session_id},
               "responder:test:expired-placement-read"
             )

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(database_now!(), -1, :second)]
    )

    requirements = %{
      capability_names: ["responder-state"],
      repository_ref: "responder",
      workspace_ref: "workspace-main"
    }

    assert {:error, {:coop_session_replacement_required, session_id, generation}} =
             ControlPlane.place_session(placement.session_id, requirements, 60)

    assert session_id == placement.session_id
    assert generation == placement.generation
    assert Repo.get!(Placement, placement.id).state == :replaced

    # Four reads that never left Responder stayed queued after failover and kept
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
      capability_names: ["responder-state"],
      repository_ref: "responder",
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
    |> TurnChangeset.prepare_cancellation(
      intent,
      Cancellation.fingerprint(intent),
      nil
    )
    |> Repo.update!()

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(database_now!(), -1, :second)]
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

  test "a revoking placement cannot be replaced before its worker lease expires" do
    authorize_and_poll!("worker-a")
    placement = place!("revoking-placement")

    placement
    |> Ecto.Changeset.change(state: :revoking)
    |> Repo.update!()

    requirements = %{
      capability_names: ["responder-state"],
      repository_ref: "responder",
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
                 capability_names: ["responder-state"],
                 repository_ref: "responder",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, binding} =
             StateBinding.derive(
               session,
               claim.turn,
               StateBinding.placement_scope(placement),
               "https://responder.example/v1/state-tools/mcp",
               "state-tools-secret-for-tests"
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
      set: [lease_expires_at: DateTime.add(database_now!(), -1, :second)]
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
                 capability_names: ["responder-state"],
                 repository_ref: "responder",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, binding} =
             StateBinding.derive(
               session,
               claim.turn,
               StateBinding.placement_scope(first_placement),
               "https://responder.example/v1/state-tools/mcp",
               "state-tools-secret-for-tests"
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
      lease_expires_at: DateTime.add(database_now!(), 60, :second),
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

    assert ControlPlane.handle_poll("worker-a", skewed) ==
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
               %{"submission_sha256" => String.duplicate("c", 64), "turn_ref" => "turn-2"},
               "responder:work:turn:turn-2:g1"
             )

    assert {:ok, first} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:command:1")
             )

    assert [delivered] = first["commands"]
    assert delivered["command_id"] == command.id
    assert delivered["placement_generation"] == placement.generation
    assert delivered["lease_ref"] == placement.lease_ref

    assert {:ok, repeated} =
             ControlPlane.handle_poll(
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
             ControlPlane.handle_poll("worker-a", acknowledged)

    assert acknowledged_redelivery["command_id"] == command.id
    assert Repo.get!(Command, command.id).status == :acknowledged

    resource = %{"session_id" => "coop-session-1", "turn_id" => "coop-turn-1"}

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

    assert {:ok, first_result_response} = ControlPlane.handle_poll("worker-a", completed)
    assert first_result_response["acknowledged_result_command_ids"] == [command.id]

    assert {:ok, replayed_result_response} = ControlPlane.handle_poll("worker-a", completed)
    assert replayed_result_response["acknowledged_result_command_ids"] == [command.id]

    settled = Repo.get!(Command, command.id)
    assert settled.status == :succeeded
    assert settled.result == resource

    changed = put_in(completed, ["command_results", Access.at(0), "resource", "turn_id"], "wrong")
    command_id = command.id

    assert {:error, {:coop_worker_command_result_conflict, ^command_id}} =
             ControlPlane.handle_poll("worker-a", changed)
  end

  test "a worker result cannot cross its expired placement generation" do
    authorize_and_poll!("worker-a")
    placement = place!("expired-command-result")

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "submit_turn",
               %{"submission_sha256" => String.duplicate("c", 64), "turn_ref" => "turn-expired"},
               "responder:work:turn:expired:g1"
             )

    assert {:ok, %{"commands" => [%{"command_id" => command_id}]}} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:expired-result:1")
             )

    assert command_id == command.id

    Repo.update_all(
      from(value in Placement, where: value.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(database_now!(), -1, :second)]
    )

    result = %{
      "command_id" => command.id,
      "error" => nil,
      "operation_key" => command.idempotency_key,
      "resource" => %{"session_id" => "coop-session-expired", "turn_id" => "coop-turn-expired"},
      "state" => "succeeded"
    }

    assert {:ok, response} =
             ControlPlane.handle_poll(
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
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:expired-result:3",
                 command_results: [result]
               )
             )

    assert replay["acknowledged_result_command_ids"] == [command.id]
  end

  test "a state bearer exists only in the response for its exact current placement" do
    secret = "fleet-state-binding-secret"
    endpoint = "https://responder.example/v1/state-tools/mcp"

    authorize_and_poll!("worker-a")
    session = session!("state-binding-command")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
                 repository_ref: "responder",
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
               %{"responder_binding" => descriptor, "turn_ref" => claim.turn.turn_ref},
               "responder:work:turn:state-binding:g1"
             )

    persisted = Repo.get!(Command, command.id)
    assert persisted.payload["responder_binding"] == descriptor
    refute inspect(persisted.payload) =~ binding.token

    assert {:ok, %{"commands" => [delivered]}} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:state-binding"),
               state_tools_secret: secret
             )

    assert delivered["payload"]["responder_binding"] == StateBinding.document(binding)
    refute Repo.get!(Command, command.id).payload["responder_binding"]["token"]
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
               "responder:work:validation:large:g1"
             )

    assert command.payload == payload

    assert {:ok, _command} =
             ControlPlane.enqueue_command(
               placement.id,
               "fence_operation",
               %{"method" => "SubmitTurn", "request" => %{}},
               "responder:work:fence:large:g1"
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

    assert {:ok, response} = ControlPlane.handle_poll("worker-a", event_poll)

    assert response["event_acknowledgements"] == [
             %{
               "placement_generation" => placement.generation,
               "sequence" => 2,
               "session_ref" => placement.session_id
             }
           ]

    assert Repo.aggregate(Event, :count) == 2
    assert Repo.get!(Placement, placement.id).last_acked_event_sequence == 2

    assert {:ok, replayed} = ControlPlane.handle_poll("worker-a", event_poll)
    assert replayed["event_acknowledgements"] == response["event_acknowledgements"]
    assert Repo.aggregate(Event, :count) == 2

    changed =
      put_in(
        event_poll,
        ["event_batches", Access.at(0), "events", Access.at(1), "payload", "state"],
        "completed"
      )

    assert {:error, {:coop_worker_event_replay_conflict, 2}} =
             ControlPlane.handle_poll("worker-a", changed)
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

    assert {:ok, _response} = ControlPlane.handle_poll("worker-a", coarse_poll)

    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^placement.session_id),
        set: [coop_session_id: coop_session_id]
      )

    now = database_now!() |> DateTime.to_iso8601()

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

    assert {:ok, response} = ControlPlane.handle_poll("worker-a", event_poll)
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

    assert {:ok, _replayed} = ControlPlane.handle_poll("worker-a", event_poll)
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

    now = database_now!() |> DateTime.to_iso8601()

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
             ControlPlane.handle_poll(
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
    now = database_now!() |> DateTime.to_iso8601()

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
             ControlPlane.handle_poll(
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
             ControlPlane.handle_poll(
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
             ControlPlane.handle_poll(
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
    |> SessionChangeset.bind_workspace_task(workspace_task)
    |> Repo.update!()

    now = database_now!() |> DateTime.to_iso8601()

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
             ControlPlane.handle_poll(
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
               "responder:workspace:pre-bind-task"
             )

    assert {:ok, %{"commands" => [%{"command_id" => command_id}]}} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:pre-bind-task-deliver")
             )

    assert command_id == command.id

    bound_task = %{
      "draft_sha256" => String.duplicate("a", 64),
      "id" => "responder-pre-bind-task",
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

    assert {:error, {:coop_activity_session_conflict, ^coop_session_id}} =
             ControlPlane.handle_poll("worker-a", unproven_event_poll)

    remote = %{
      "id" => coop_session_id,
      "revision" => 2,
      "state" => "open",
      "workspace_task" => bound_task
    }

    assert {:ok, %{"acknowledged_result_command_ids" => [^command_id]}} =
             ControlPlane.handle_poll(
               "worker-a",
               poll("worker-a", "workspace-main", "poll:worker-a:pre-bind-task-result",
                 command_results: [
                   %{
                     "command_id" => command.id,
                     "error" => nil,
                     "operation_key" => command.idempotency_key,
                     "resource" => %{"session" => remote},
                     "state" => "succeeded"
                   }
                 ]
               )
             )

    placement
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(database_now!(), -1, :second))
    |> Repo.update!()

    # The third live retry bound the exact task, but its lifecycle event arrived before the
    # local session ID was stored and outlived its short placement lease. Rejecting that event
    # returned HTTP 400 on every later poll.
    assert {:ok, response} =
             ControlPlane.handle_poll(
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

    assert {:ok, _response} = ControlPlane.handle_poll("worker-a", first)

    placement |> Ecto.Changeset.change(state: :revoking) |> Repo.update!()

    replay =
      poll("worker-a", "workspace-main", "poll:worker-a:event-authority:2",
        event_batches: [batch]
      )

    assert {:ok, _response} = ControlPlane.handle_poll("worker-a", replay)

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

    assert {:error, {:coop_worker_event_placement_not_authorized, ^placement_id}} =
             ControlPlane.handle_poll("worker-a", rejected)
  end

  test "an expired placement can finish publishing its bound public session activity" do
    authorize_and_poll!("worker-a")
    placement = place!("late-bound-activity")
    coop_session_id = "coop-late-bound-activity"

    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^placement.session_id),
        set: [coop_session_id: coop_session_id]
      )

    expired_at = database_now!() |> DateTime.add(-5, :second)

    placement
    |> Ecto.Changeset.change(lease_expires_at: expired_at)
    |> Repo.update!()

    event = %{
      "kind" => "session_event",
      "payload" => %{
        "id" => "evt-late-progress",
        "occurred_at" => database_now!() |> DateTime.to_iso8601(),
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
             ControlPlane.handle_poll(
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
        "occurred_at" => database_now!() |> DateTime.to_iso8601(),
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

    assert {:error, {:coop_worker_event_placement_not_authorized, _placement_id}} =
             ControlPlane.handle_poll("worker-a", wrong_session)

    # One discarded workspace event blocked every later heartbeat in production,
    # taking the only editing worker and the whole service out of readiness.
    assert {:ok, response} = ControlPlane.handle_poll("worker-a", terminal_poll)

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

  defp authorize_and_poll!(worker_id, options \\ []) do
    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               worker_id,
               "workspace-main",
               certificate_digest(worker_id)
             )

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               worker_id,
               poll(worker_id, "workspace-main", "poll:#{worker_id}:hello", options)
             )
  end

  defp certificate_digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp place!(suffix) do
    session = session!(suffix)

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
                 repository_ref: "responder",
                 workspace_ref: "workspace-main"
               },
               60
             )

    placement
  end

  defp session!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "fleet:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: database_now!(),
        turn_ref: "turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               @policy_digest,
               @authority_digest,
               "responder"
             )

    session
  end

  defp poll(worker_id, workspace_ref, poll_ref, options \\ []) do
    repositories =
      options
      |> Keyword.get(:repositories, ["responder"])
      |> Enum.map(&%{"ref" => &1, "revision" => "commit:abc123"})

    %{
      "acknowledged_command_ids" => Keyword.get(options, :acknowledged_command_ids, []),
      "command_results" => Keyword.get(options, :command_results, []),
      "event_batches" => Keyword.get(options, :event_batches, []),
      "poll_ref" => poll_ref,
      "version" => 1,
      "worker" => %{
        "build_version" => "coop-abc123",
        "capabilities" =>
          Keyword.get(options, :capabilities, [
            %{"name" => "responder-state", "version" => "1"}
          ]),
        "capacity" => Keyword.get(options, :capacity, capacity(2, 4)),
        "clock_at" => DateTime.to_iso8601(database_now!()),
        "id" => worker_id,
        "policy_authority_digests" => %{
          "work-read-only" => Keyword.get(options, :authority_digest, @authority_digest)
        },
        "policy_digests" => %{"work-read-only" => @policy_digest},
        "protocol_version" => "1",
        "repositories" => repositories,
        "sandbox_digest" => @sandbox_digest,
        "state" => "eligible",
        "workspace_ref" => workspace_ref
      }
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

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
