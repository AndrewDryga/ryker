defmodule Ryker.Work.CustodyTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.CoopFleet.ControlPlane, as: FleetControlPlane
  alias Ryker.CoopFleet.{Worker, WorkspaceCheckpointTransfer}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Work.{Cancellation, Custody, Submission, Turn, TurnChangeset}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @authority_digest String.duplicate("f", 64)
  @policy_digest String.duplicate("b", 64)
  @actor "control-plane:local"

  test "one worker owns one durable logical turn and episode session" do
    command = create_episode!("one-owner")

    assert {:ok, claim} = Custody.claim_next("worker:a", 60)
    assert claim.episode.key == command.episode_key
    assert claim.turn.turn_ref == command.turn_ref
    assert claim.turn.status == :pending
    assert claim.turn.submit_generation == 1
    assert claim.turn.validation_generation == 1
    assert claim.session.episode_id == claim.episode.id
    assert claim.session.policy == "work-read-only"
    assert claim.session.generation == 1
    assert claim.session.create_generation == 1
    assert claim.session.coop_session_id == nil
    assert {:ok, nil} = Custody.claim_next("worker:b", 60)
  end

  test "an unpinned episode cannot starve later authorized work" do
    unpinned = create_kernel_episode!("unpinned-oldest")

    {1, nil} =
      Repo.update_all(
        from(episode in Ryker.Episodes.Episode,
          where: episode.id == ^unpinned.episode_id
        ),
        set: [updated_at: ~U[2000-01-01 00:00:00.000000Z]]
      )

    pinned = create_episode!("pinned-later")

    assert {:ok, claim} = Custody.claim_next("worker:authorized", 60)
    assert claim.episode.id == pinned.episode_id
    assert claim.session.policy == "work-read-only"
  end

  test "an existing episode keeps its pinned policy when the configured default changes" do
    command = create_kernel_episode!("policy-default-evolves")

    assert {:ok, pinned} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("a", 64),
               @authority_digest,
               "infrastructure"
             )

    assert pinned.repository_ref == "infrastructure"
    assert pinned.authority_digest == @authority_digest

    assert {:ok, original} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only-v2",
               String.duplicate("b", 64),
               String.duplicate("e", 64),
               "backend"
             )

    assert original.policy == "work-read-only"
    assert original.authority_digest == @authority_digest
    assert original.repository_ref == "infrastructure"

    assert {:ok, claim} = Custody.claim_next("worker:new-default", 60)
    assert claim.session.id == original.id
    assert claim.session.policy == "work-read-only"
    assert claim.session.repository_ref == "infrastructure"
  end

  test "a model change moves an episode onto its policy's current digest when authority is unchanged" do
    # Choosing another model in Settings changes a policy's digest but not its
    # authority. The session stayed pinned to the old digest, no worker
    # advertised it any more, and the conversation's next turn blocked as "no
    # eligible worker with available capacity".
    command = create_kernel_episode!("model-moved")
    old = String.duplicate("a", 64)
    new = String.duplicate("b", 64)

    assert {:ok, pinned} =
             Custody.pin_episode(command.episode_id, "ryker-chat", old, @authority_digest, nil)

    binding!("ryker-chat", new, @authority_digest)
    assert Custody.current_policy_digest(pinned) == new

    # No worker has created this session yet, so it takes the current digest.
    assert {:ok, claim} = Custody.claim_next("worker:model-moved", 60)
    assert claim.session.id == pinned.id
    assert claim.session.policy == "ryker-chat"
    assert claim.session.policy_digest == new
    assert claim.session.authority_digest == @authority_digest
  end

  test "a policy whose authority changed keeps an episode on its pinned digest" do
    # Only a model change is followed. Different tools or repository access
    # would change what the running work may do, so the pin stands.
    command = create_kernel_episode!("authority-moved")
    old = String.duplicate("a", 64)

    assert {:ok, pinned} =
             Custody.pin_episode(command.episode_id, "ryker-chat", old, @authority_digest, nil)

    binding!("ryker-chat", String.duplicate("b", 64), String.duplicate("c", 64))
    assert Custody.current_policy_digest(pinned) == old

    assert {:ok, claim} = Custody.claim_next("worker:authority-moved", 60)
    assert claim.session.policy_digest == old
  end

  test "a frozen turn context and Coop session survive lease expiry" do
    create_episode!("crash-recovery")
    assert {:ok, first} = Custody.claim_next("worker:a", 30)

    model_context = %{
      "episode_id" => first.episode.id,
      "semantic_version" => first.episode.semantic_version,
      "turn_ref" => first.turn.turn_ref
    }

    submission = submission!(model_context)

    assert {:ok, frozen} =
             Custody.freeze_submission(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               submission
             )

    assert frozen.submission == submission
    assert byte_size(frozen.submission_fingerprint) == 64

    assert {:ok, session} =
             Custody.bind_session(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               first.session.generation,
               first.session.create_generation,
               "remote_episode_1"
             )

    assert session.coop_session_id == "remote_episode_1"

    expire_lease!(first.turn.id)
    assert {:ok, recovered} = Custody.claim_next("worker:b", 30)
    assert recovered.turn.id == first.turn.id
    assert recovered.turn.submission == submission
    assert recovered.turn.submission_fingerprint == frozen.submission_fingerprint
    assert recovered.session.id == first.session.id
    assert recovered.session.coop_session_id == "remote_episode_1"
  end

  test "a retry cannot replace the frozen context or episode session" do
    create_episode!("immutable-bindings")
    assert {:ok, claim} = Custody.claim_next("worker:a", 60)

    first_submission = submission!(%{"request" => "first"})
    different_submission = submission!(%{"request" => "different"})

    assert {:ok, _turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               first_submission
             )

    assert {:error, {:work_submission_conflict, _stored_fingerprint}} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               different_submission
             )

    assert {:ok, _session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote_episode_1"
             )

    assert {:ok, _session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote_episode_1"
             )

    assert {:error, {:work_session_conflict, "remote_episode_1"}} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote_episode_2"
             )
  end

  test "renewal extends only the current fenced lease" do
    create_episode!("lease-renewal")
    assert {:ok, claim} = Custody.claim_next("worker:a", 30)

    assert {:ok, renewed} =
             Custody.renew(claim.episode.id, claim.turn.turn_ref, claim.lease_ref, 90)

    assert DateTime.compare(renewed.lease_expires_at, claim.turn.lease_expires_at) == :gt

    assert {:error, :work_lease_lost} =
             Custody.renew(
               claim.episode.id,
               claim.turn.turn_ref,
               "work-lease:stale",
               90
             )

    assert {:ok, nil} = Custody.claim_next("worker:b", 30)
  end

  test "only a confirmed pre-resource failure spends an operation generation" do
    create_episode!("operation-generations")
    assert {:ok, claim} = Custody.claim_next("worker:a", 60)

    assert {:ok, create_retry} =
             Custody.advance_session_create(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1
             )

    assert create_retry.create_generation == 2

    assert {:error, {:work_session_create_generation_conflict, 2}} =
             Custody.advance_session_create(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1
             )

    submission = submission!(%{"request" => "retry-safe"})

    assert {:ok, frozen} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               create_retry.create_generation,
               "remote_episode_retry"
             )

    assert {:error, :work_session_already_bound} =
             Custody.advance_session_create(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               create_retry.create_generation
             )

    assert {:ok, submit_retry} =
             Custody.advance_turn_submit(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1
             )

    assert submit_retry.submit_generation == 2
    assert submit_retry.submission == frozen.submission

    assert {:ok, bound} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               submit_retry.submit_generation,
               "remote_turn_2"
             )

    assert bound.coop_turn_id == "remote_turn_2"

    assert {:ok, exact_retry} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               submit_retry.submit_generation,
               "remote_turn_2"
             )

    assert exact_retry.id == bound.id

    assert {:error, {:work_turn_conflict, "remote_turn_2"}} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               submit_retry.submit_generation,
               "different_turn"
             )

    assert {:error, :work_turn_already_bound} =
             Custody.advance_turn_submit(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submit_retry.submit_generation
             )
  end

  test "two episodes may use the same episode-scoped turn reference" do
    first = create_episode!("shared-ref-a", "turn:shared")
    second = create_episode!("shared-ref-b", "turn:shared")

    assert {:ok, first_claim} =
             Custody.claim_next("worker:a", 60)

    assert {:ok, second_claim} =
             Custody.claim_next("worker:b", 60)

    assert MapSet.new([first_claim.episode.key, second_claim.episode.key]) ==
             MapSet.new([first.episode_key, second.episode_key])

    assert first_claim.turn.turn_ref == "turn:shared"
    assert second_claim.turn.turn_ref == "turn:shared"
    refute first_claim.turn.episode_id == second_claim.turn.episode_id
  end

  test "a worker loses custody as soon as an owner transfer is requested" do
    command = create_episode!("owner-fence")
    assert {:ok, claim} = Custody.claim_next("worker:a", 60)

    assert {:ok, requested} =
             Custody.request_transfer(
               claim.episode.id,
               command.episode_key,
               command.turn_ref,
               "turn:replacement",
               "transfer:#{Ecto.UUID.generate()}"
             )

    assert requested.turn.status == :cancel_pending
    assert requested.episode.owner_ref == command.turn_ref

    assert {:error, :work_turn_not_found} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission!(%{"request" => "stale"})
             )

    assert {:error, :work_turn_not_found} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote_stale"
             )

    assert {:ok, cancellation_claim} = Custody.claim_next("worker:transfer-cleanup", 60, :work)

    assert {:ok, receipt} =
             Cancellation.absent_receipt(
               "ryker:work:create:#{claim.session.id}:g#{claim.session.create_generation}",
               nil,
               nil,
               nil,
               nil
             )

    assert {:ok, _settled} =
             Custody.settle_cancellation(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               cancellation_claim.lease_ref,
               receipt
             )

    assert {:error, :work_turn_not_claimable} =
             Custody.renew(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               60
             )

    assert {:ok, replacement} = Custody.claim_next("worker:b", 60)
    assert replacement.turn.turn_ref == "turn:replacement"
    assert replacement.session.policy == claim.session.policy
    assert replacement.session.generation == claim.session.generation
    assert replacement.session.id == claim.session.id

    stale_turn = Repo.get!(Turn, claim.turn.id)
    assert stale_turn.status == :superseded
    assert stale_turn.last_error_code == "owner_transferred"
    assert stale_turn.lease_ref == nil
  end

  test "the database refuses a turn bound to another episode's Coop session" do
    create_episode!("session-episode-a")
    assert {:ok, first} = Custody.claim_next("worker:a", 60)

    create_episode!("session-episode-b")
    assert {:ok, second} = Custody.claim_next("worker:b", 60)

    assert {:error, changeset} =
             Ecto.UUID.generate()
             |> TurnChangeset.insert(
               second.episode.id,
               first.session.id,
               "turn:cross-episode:#{Ecto.UUID.generate()}"
             )
             |> Repo.insert()

    assert {"does not exist", _metadata} = changeset.errors[:session_id]
  end

  test "session and turn generations reject out-of-order remote bindings" do
    create_episode!("binding-order")
    assert {:ok, claim} = Custody.claim_next("worker:binding-order", 60)

    assert {:error, {:work_session_generation_conflict, 1}} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               2,
               1,
               "remote:wrong-session-generation"
             )

    assert {:error, {:work_session_create_generation_conflict, 1}} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1,
               2,
               "remote:wrong-create-generation"
             )

    assert {:error, :work_session_not_bound} =
             Custody.rotate_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1
             )

    assert {:error, :work_session_not_bound} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1,
               1,
               "remote:turn-before-session"
             )

    assert {:error, :work_session_not_bound} =
             Custody.advance_turn_submit(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1,
               1,
               "remote:binding-order"
             )

    assert {:error, {:work_session_generation_conflict, 1}} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               2,
               1,
               "remote:wrong-turn-session"
             )

    assert {:error, {:work_turn_submit_generation_conflict, 1}} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               2,
               "remote:wrong-submit-generation"
             )

    assert {:error, :work_submission_not_frozen} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               1,
               "remote:turn-before-freeze"
             )

    assert {:error, :work_submission_not_frozen} =
             Custody.advance_turn_submit(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission!(%{"request" => "binding order"})
             )

    assert {:error, :work_session_rotation_requires_unfrozen_submission} =
             Custody.rotate_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation
             )
  end

  test "candidate validation cannot outrun its bound remote turn" do
    create_episode!("candidate-order")
    assert {:ok, claim} = Custody.claim_next("worker:candidate-order", 60)
    candidate = ~s({"message":"candidate"})
    candidate_sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:error, :work_turn_not_bound} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert {:error, :work_turn_not_bound} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               {:reject, ["not ready"]},
               nil
             )

    assert {:ok, _submission} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission!(%{"request" => "candidate order"})
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1,
               1,
               "remote:candidate-order"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               1,
               "remote:turn:candidate-order"
             )

    assert {:ok, staged} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    different = ~s({"message":"different"})
    different_sha256 = :crypto.hash(:sha256, different) |> Base.encode16(case: :lower)

    assert {:error, {:work_candidate_attempt_conflict, 1}} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               staged.candidate_sha256,
               staged.candidate_attempt,
               different,
               different_sha256,
               1
             )

    assert {:error, {:work_candidate_conflict, ^candidate_sha256}} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               String.duplicate("0", 64),
               1,
               different,
               different_sha256,
               2
             )

    assert {:error, :work_validation_intent_not_frozen} =
             Custody.advance_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               1
             )

    assert {:ok, exact_candidate_retry} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert exact_candidate_retry.id == staged.id

    assert {:ok, intent} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               {:reject, ["not ready"]},
               nil
             )

    assert {:ok, exact_intent_retry} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               {:reject, ["not ready"]},
               nil
             )

    assert exact_intent_retry.validation_intent_fingerprint ==
             intent.validation_intent_fingerprint

    assert [rejected_attempt] = exact_intent_retry.validation_history
    assert rejected_attempt["candidate_attempt"] == 1
    assert rejected_attempt["candidate_sha256"] == candidate_sha256
    assert rejected_attempt["intent_fingerprint"] == intent.validation_intent_fingerprint
    assert rejected_attempt["parse"] == "JSON object"
    assert rejected_attempt["response_bytes"] == byte_size(candidate)
    assert rejected_attempt["verdict"] == "reject"
    assert rejected_attempt["violations"] == ["not ready"]
    assert {:ok, _recorded_at, 0} = DateTime.from_iso8601(rejected_attempt["recorded_at"])

    assert {:error, {:work_validation_intent_conflict, stored_intent}} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               {:reject, ["different correction"]},
               nil
             )

    assert stored_intent == intent.validation_intent_fingerprint

    assert Custody.advance_validation(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             candidate_sha256,
             1,
             2
           ) == {:error, {:work_validation_generation_conflict, 1}}

    assert {:ok, advanced} =
             Custody.advance_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               1
             )

    assert advanced.validation_generation == 2

    assert {:ok, replaced} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               different,
               different_sha256,
               2
             )

    assert replaced.candidate_attempt == 2
    assert replaced.validation_intent == nil
    assert replaced.validation_history == [rejected_attempt]
  end

  test "outbound mutation fences reject malformed identity before invoking Coop" do
    create_episode!("mutation-fence-contract")
    assert {:ok, claim} = Custody.claim_next("worker:mutation-fence-contract", 60)
    callback = fn -> flunk("invalid mutation request reached Coop") end

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             %{},
             callback
           ) == {:error, {:invalid_work_mutation_fence, :request}}

    base = %{
      kind: :create_session,
      lease_seconds: 60,
      operation_key: "operation:mutation-fence-contract",
      operation_revision: nil
    }

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             %{base | kind: :unknown},
             callback
           ) == {:error, {:invalid_work_custody, :remote_operation_kind}}

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             %{base | operation_revision: 1},
             callback
           ) == {:error, {:invalid_work_custody, :remote_operation_revision}}

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             %{base | kind: :submit_turn},
             callback
           ) == {:error, {:invalid_work_custody, :remote_operation_revision}}

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             base,
             :not_a_callback
           ) == {:error, {:invalid_work_custody, :callback}}

    assert Custody.claim_next("worker:invalid-phase", 60, :unknown) ==
             {:error, {:invalid_work_custody, :phase}}
  end

  test "outbound mutation identity is frozen before Coop and cannot be rebound" do
    create_episode!("mutation-fence-identity")
    assert {:ok, claim} = Custody.claim_next("worker:mutation-fence-identity", 60)

    create = %{
      kind: :create_session,
      lease_seconds: 60,
      operation_key: "operation:create:mutation-fence-identity",
      operation_revision: nil
    }

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             create,
             fn -> :sent end
           ) == :sent

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             create,
             fn -> :exact_retry end
           ) == :exact_retry

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             %{create | operation_key: "operation:create:different"},
             fn -> flunk("a conflicting operation reached Coop") end
           ) ==
             {:error,
              {:work_remote_operation_conflict,
               {"create_session", "operation:create:mutation-fence-identity"}}}

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             "work-lease:stale",
             create,
             fn -> flunk("a stale worker reached Coop") end
           ) == {:error, :work_lease_lost}
  end

  # Found live 2026-09-12 — an operator retry of a failed create blocked instantly on
  # work_remote_operation_in_flight and every further retry repeated it; the documented
  # recovery path had no exit. Releasing a create that never reached Coop is the missing
  # third outcome, not an override: it clears one exact key, under the turn's own lease,
  # and spends nothing.
  test "releasing a create fence needs the exact key it was frozen with" do
    create_episode!("release-create-fence")
    assert {:ok, claim} = Custody.claim_next("worker:release-create-fence", 60)

    create = %{
      kind: :create_session,
      lease_seconds: 60,
      operation_key: "operation:create:release-create-fence",
      operation_revision: nil
    }

    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             create,
             fn -> :sent end
           ) == :sent

    assert Custody.release_session_create(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             "operation:create:another"
           ) ==
             {:error,
              {:work_remote_operation_conflict,
               {"create_session", "operation:create:release-create-fence"}}}

    assert Custody.release_session_create(
             claim.episode.id,
             claim.turn.turn_ref,
             "work-lease:stale",
             create.operation_key
           ) == {:error, :work_lease_lost}

    assert {:ok, released} =
             Custody.release_session_create(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               create.operation_key
             )

    assert released.remote_operation_kind == nil
    assert released.remote_operation_key == nil

    # The key was never used, so it is not spent: the next attempt reuses it and the
    # session stays on the same create generation.
    assert Custody.with_mutation_fence(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             create,
             fn -> :retried end
           ) == :retried

    assert Repo.get!(Ryker.Work.Session, claim.session.id).create_generation ==
             claim.session.create_generation
  end

  test "state tools bind the exact turn after its remote session exists" do
    create_episode!("state-binding-order")
    assert {:ok, claim} = Custody.claim_next("worker:state-binding-order", 60)

    assert {:ok, _session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:state-binding-order"
             )

    assert {:ok, bound_turn} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               "https://state.example.test/mcp",
               String.duplicate("b", 64)
             )

    assert bound_turn.id == claim.turn.id
    assert bound_turn.state_tools_endpoint == "https://state.example.test/mcp"
  end

  test "session rotation is generation-fenced and refuses a bound remote turn" do
    create_episode!("rotation-fence")
    assert {:ok, claim} = Custody.claim_next("worker:rotation-fence", 60)

    assert {:ok, bound_session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:rotation-fence"
             )

    assert {:error, {:work_session_generation_conflict, 1}} =
             Custody.rotate_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               2
             )

    assert {:ok, %{session: replacement}} =
             Custody.rotate_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               bound_session.generation
             )

    assert replacement.generation == 2

    assert {:ok, _submission} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission!(%{"request" => "rotation fence"})
             )

    assert {:ok, _bound_replacement} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               replacement.generation,
               replacement.create_generation,
               "remote:rotation-replacement"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               replacement.generation,
               1,
               "remote:turn:rotation-fence"
             )

    assert Custody.rotate_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             replacement.generation
           ) == {:error, :work_turn_already_bound}
  end

  # A replacement generation is the same custody, never a new resolution: it
  # keeps the environment the work started in (and with it the Emisar pin and
  # the mounted repositories) even if the environment changed since.
  test "session rotation preserves the pinned writable workspace task" do
    command = create_kernel_episode!("workspace-task-rotation")

    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "offer_ref" => "record:task_offer:workspace-task-rotation",
      "prompt" => "Continue the exact writable workspace.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Preserve workspace authority"
    }

    repository_context = %{
      "context_ref" => "platform",
      "parallel_goal_limit" => 2,
      "primary_repository" => "ryker",
      "read_only_repositories" => ["coop"]
    }

    assert {:ok, {:ok, pinned}} =
             Repo.transaction(fn ->
               Custody.pin_task_episode_in_transaction(
                 command.episode_id,
                 "work-writable",
                 String.duplicate("a", 64),
                 "ryker",
                 repository_context,
                 workspace_task,
                 nil,
                 "platform"
               )
             end)

    assert pinned.workspace_task == workspace_task
    assert pinned.environment_ref == "platform"
    assert {:ok, claim} = Custody.claim_next("worker:workspace-task-rotation", 60)

    assert {:ok, bound_session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:workspace-task-rotation"
             )

    assert {:ok, %{session: replacement}} =
             Custody.rotate_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               bound_session.generation
             )

    assert replacement.generation == 2
    assert replacement.repository_ref == "ryker"
    assert replacement.repository_context == repository_context
    assert replacement.environment_ref == "platform"
    assert replacement.workspace_task == workspace_task
  end

  test "malformed custody commands fail with typed errors before touching durable work" do
    episode_id = Ecto.UUID.generate()
    digest = String.duplicate("a", 64)
    ref = "bounded-ref"

    assert Custody.pin_episode_in_transaction(episode_id, ref, digest) ==
             {:error, :work_transaction_required}

    assert Custody.pin_episode(episode_id, ref, digest) == {:error, :episode_not_found}

    assert {:error, {:invalid_work_custody, :repository_ref}} =
             Custody.pin_episode(episode_id, ref, digest, <<0>>)

    assert {:error, {:invalid_work_submission, :fields}} =
             Custody.freeze_submission(episode_id, ref, ref, :invalid)

    assert {:error, {:invalid_work_custody, :final_preflight_candidate_sha256}} =
             Custody.record_final_preflight(episode_id, ref, ref, "bad", digest, 1)

    assert {:error, {:invalid_work_custody, :final_preflight_semantic_version}} =
             Custody.record_final_preflight(episode_id, ref, ref, digest, digest, -1)

    assert {:error, {:invalid_work_custody, :artifact_refs}} =
             Custody.verify_final_preflight(episode_id, ref, ref, digest, :invalid)

    assert {:error, {:invalid_work_custody, :state_tools_endpoint}} =
             Custody.bind_state_tools(episode_id, ref, ref, "", digest)

    assert {:error, {:invalid_work_custody, :state_tools_token_sha256}} =
             Custody.bind_state_tools(episode_id, ref, ref, "https://state.test/mcp", "bad")

    assert {:error, {:invalid_work_custody, :session_generation}} =
             Custody.bind_session(episode_id, ref, ref, 0, 1, "coop-session")

    assert {:error, {:invalid_work_custody, :create_generation}} =
             Custody.advance_session_create(episode_id, ref, ref, 0)

    assert {:error, {:invalid_work_custody, :session_generation}} =
             Custody.rotate_session(episode_id, ref, ref, 0)

    assert {:error, {:invalid_work_custody, :session_generation}} =
             Custody.replace_session_after_placement_loss(episode_id, ref, ref, 0)

    assert {:error, {:invalid_work_custody, :submit_generation}} =
             Custody.bind_turn(episode_id, ref, ref, 1, 0, "coop-turn")

    assert {:error, {:invalid_work_custody, :submit_generation}} =
             Custody.advance_turn_submit(episode_id, ref, ref, 0)

    assert {:error, {:invalid_work_custody, :expected_candidate_identity}} =
             Custody.stage_candidate(episode_id, ref, ref, digest, nil, "{}", digest, 1)

    assert {:error, {:invalid_work_custody, :candidate}} =
             Custody.stage_candidate(episode_id, ref, ref, nil, nil, :invalid, digest, 1)

    assert {:error, {:invalid_work_custody, :candidate_attempt}} =
             Custody.stage_candidate(episode_id, ref, ref, nil, nil, "{}", digest, 0)

    assert {:error, {:invalid_work_custody, :candidate_sha256}} =
             Custody.stage_candidate(episode_id, ref, ref, nil, nil, "{}", digest, 1)

    assert {:error, {:invalid_work_custody, :validation_generation}} =
             Custody.advance_validation(episode_id, ref, ref, digest, 1, 0)

    assert {:error, {:invalid_work_custody, :measurement}} =
             Custody.accept_result(episode_id, ref, ref, ref, digest, 1, ref, :invalid)

    assert {:error, {:invalid_work_custody, :cancellation_revision_phase}} =
             Custody.freeze_cancellation_revision(episode_id, ref, ref, :invalid, 1)

    assert {:error, {:invalid_work_custody, :cancellation_revision}} =
             Custody.freeze_cancellation_revision(episode_id, ref, ref, :cancel_turn, 0)

    assert {:error, {:invalid_work_cancellation, :receipt}} =
             Custody.settle_cancellation(episode_id, ref, ref, ref, %{})

    assert {:error, {:invalid_work_custody, :lease_seconds}} =
             Custody.renew(episode_id, ref, ref, 0)

    assert {:error, {:invalid_work_custody, :retry_seconds}} =
             Custody.defer(episode_id, ref, ref, 0, "error", "detail")

    assert {:error, {:invalid_work_custody, :error_code}} =
             Custody.block_delivery(episode_id, ref, ref, "", "detail")

    assert {:error, {:invalid_work_custody, :delivery_ref}} =
             Custody.retry_delivery(episode_id, ref, <<0>>)

    assert {:error, {:invalid_work_custody, :retry_seconds}} =
             Custody.yield_progress(episode_id, ref, ref, 0)
  end

  test "durable Work phases cannot be applied out of order" do
    command = create_episode!("phase-order")
    assert {:ok, claim} = Custody.claim_next("worker:phase-order", 60)
    digest = :crypto.hash(:sha256, "{}") |> Base.encode16(case: :lower)

    assert Custody.verify_final_preflight(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             digest,
             []
           ) == {:error, :work_final_preflight_required}

    assert {:error, reason} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.turn.submit_generation,
               "remote-turn"
             )

    assert reason in [:work_submission_not_frozen, :work_session_not_bound]

    assert {:error, :work_turn_not_bound} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               "{}",
               digest,
               1
             )

    assert {:error, :work_turn_not_bound} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               digest,
               1,
               {:reject, ["candidate is incomplete"]},
               nil
             )

    assert {:error, {:work_candidate_conflict, nil}} =
             Custody.advance_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               digest,
               1,
               1
             )

    assert {:error, reason} =
             Custody.accept_result(
               claim.episode.id,
               command.episode_key,
               claim.turn.turn_ref,
               claim.lease_ref,
               digest,
               1,
               "validation-receipt"
             )

    assert reason in [:work_validation_intent_not_frozen, :work_candidate_not_staged]

    receipt = %{
      "conversation_ref" => claim.episode.destination_conversation_ref,
      "delivery_ref" => "delivery:phase-order",
      "message_ref" => "message:phase-order",
      "thread_ref" => claim.episode.destination_thread_ref,
      "transport" => claim.episode.destination_transport
    }

    assert {:error, :work_delivery_receipt_mismatch} =
             Custody.confirm_delivery(
               claim.episode.id,
               command.episode_key,
               claim.turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    assert {:ok, cancellation_receipt} =
             Cancellation.absent_receipt("create-key", nil, nil, nil, nil)

    assert {:error, :work_cancellation_not_pending} =
             Custody.settle_cancellation(
               claim.episode.id,
               command.episode_key,
               claim.turn.turn_ref,
               claim.lease_ref,
               cancellation_receipt
             )

    assert {:error, :work_delivery_not_pending} =
             Custody.block_delivery(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               "delivery_failed",
               "not in delivery custody"
             )

    assert {:error, :work_delivery_ref_mismatch} =
             Custody.retry_delivery(
               claim.episode.id,
               claim.turn.turn_ref,
               "delivery:phase-order"
             )
  end

  test "frozen Coop and state-tool identities reconcile exact retries and reject rebinding" do
    create_episode!("frozen-identities")
    assert {:ok, claim} = Custody.claim_next("worker:frozen-identities", 60)
    submission = submission!(%{"input" => "first"})
    other_submission = submission!(%{"input" => "different"})
    state_digest = String.duplicate("b", 64)

    assert {:ok, frozen} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, exact_freeze_retry} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert exact_freeze_retry.submission_fingerprint == frozen.submission_fingerprint

    assert {:error, {:work_submission_conflict, stored_fingerprint}} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               other_submission
             )

    assert stored_fingerprint == frozen.submission_fingerprint

    assert {:ok, state_turn} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               "https://state.example.test/mcp",
               state_digest
             )

    assert {:ok, exact_state_retry} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               "https://state.example.test/mcp",
               state_digest
             )

    assert exact_state_retry.id == state_turn.id

    assert Custody.bind_state_tools(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             "https://other.example.test/mcp",
             state_digest
           ) == {:error, :work_state_tools_binding_conflict}

    assert Custody.bind_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation + 1,
             claim.session.create_generation,
             "remote-session"
           ) == {:error, {:work_session_generation_conflict, claim.session.generation}}

    assert Custody.bind_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.session.create_generation + 1,
             "remote-session"
           ) ==
             {:error, {:work_session_create_generation_conflict, claim.session.create_generation}}

    assert {:ok, bound_session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote-session"
             )

    assert {:ok, exact_session_retry} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote-session"
             )

    assert exact_session_retry.id == bound_session.id

    assert Custody.bind_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.session.create_generation,
             "other-remote-session"
           ) == {:error, {:work_session_conflict, "remote-session"}}

    assert Custody.advance_session_create(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.create_generation
           ) == {:error, :work_session_already_bound}

    assert Custody.rotate_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation
           ) == {:error, :work_session_rotation_requires_unfrozen_submission}

    assert Custody.bind_turn(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation + 1,
             claim.turn.submit_generation,
             "remote-turn"
           ) == {:error, {:work_session_generation_conflict, claim.session.generation}}

    assert Custody.bind_turn(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.turn.submit_generation + 1,
             "remote-turn"
           ) == {:error, {:work_turn_submit_generation_conflict, claim.turn.submit_generation}}

    assert {:ok, bound_turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.turn.submit_generation,
               "remote-turn"
             )

    assert {:ok, exact_turn_retry} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.turn.submit_generation,
               "remote-turn"
             )

    assert exact_turn_retry.id == bound_turn.id

    assert Custody.bind_turn(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.turn.submit_generation,
             "other-remote-turn"
           ) == {:error, {:work_turn_conflict, "remote-turn"}}

    assert Custody.advance_turn_submit(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.submit_generation
           ) == {:error, :work_turn_already_bound}

    assert Custody.bind_state_tools(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             "https://late.example.test/mcp",
             state_digest
           ) == {:error, :work_state_tools_binding_conflict}
  end

  test "a blocked turn is only portable when the fleet could restore it somewhere" do
    # The wiring, not the rule: the recovery surfaces ask Custody, and Custody
    # has to find this turn's own session and the operator's selected workspace
    # before the fleet can answer. Reading either one wrong offers a resume for
    # work that would restart from the repository instead.
    {:ok, %{installation: %{revision: revision}}} = Settings.initialize(@actor)
    {:ok, _snapshot} = Settings.save_work(%{workspace_ref: "workspace-main"}, revision, @actor)

    command = create_kernel_episode!("portable")

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               @policy_digest,
               @authority_digest,
               "ryker"
             )

    assert {:ok, claim} = Custody.claim_next("worker:portable", 60)
    blocked = %{claim.turn | status: :blocked}

    # No worker yet, and no checkpoint: nothing to offer.
    assert Custody.portable_workspace(blocked) == nil

    enroll!("worker-portable")
    assert Custody.portable_workspace(blocked) == nil

    checkpoint!(session)

    assert Custody.portable_workspace(blocked) == %{
             byte_size: 4_096,
             checkpoint_ref: "checkpoint:custody",
             repository_ref: "ryker"
           }

    # A turn with no session of its own has nowhere to resume from, and a turn
    # that is still running is not being resumed at all.
    assert Custody.portable_workspace(%Turn{status: :blocked}) == nil
    assert Custody.portable_workspace(claim.turn) == nil
  end

  defp enroll!(id) do
    Repo.insert!(%Worker{
      capabilities: [%{"name" => "responder-state", "version" => "1"}],
      capacity: %{
        "session_slots_free" => 2,
        "session_slots_total" => 4,
        "state" => "eligible",
        "turn_slots_free" => 2,
        "turn_slots_total" => 4,
        "workspace_slots_free" => 2,
        "workspace_slots_total" => 4
      },
      certificate_sha256: :crypto.hash(:sha256, id) |> Base.encode16(case: :lower),
      clock_at: DateTime.utc_now(),
      id: id,
      last_seen_at: DateTime.utc_now(),
      policy_authority_digests: %{"work-read-only" => @authority_digest},
      policy_digests: %{"work-read-only" => @policy_digest},
      repositories: [%{"ref" => "ryker", "revision" => "commit:abc123"}],
      state: :eligible,
      workspace_ref: "workspace-main"
    })
  end

  defp checkpoint!(session) do
    assert {:ok, placement} =
             FleetControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
                 repository_ref: session.repository_ref,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, command} =
             FleetControlPlane.enqueue_command(
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

    command =
      Repo.update!(
        Ecto.Changeset.change(command,
          completed_at: DateTime.utc_now(),
          operation_key: command.idempotency_key,
          result: %{"state" => "stored"},
          result_fingerprint: String.duplicate("d", 64),
          status: :succeeded
        )
      )

    Repo.insert!(%WorkspaceCheckpointTransfer{
      bundle_byte_size: 4_096,
      bundle_sha256: String.duplicate("c", 64),
      checkpoint_ref: "checkpoint:custody",
      ciphertext: :binary.copy(<<3>>, 4_096),
      command_id: command.id,
      descriptor: %{"checkpoint_ref" => "checkpoint:custody"},
      encryption_key_sha256: String.duplicate("a", 64),
      encryption_nonce: :binary.copy(<<1>>, 12),
      encryption_tag: :binary.copy(<<2>>, 16),
      id: Ecto.UUID.generate(),
      placement_generation: command.placement_generation,
      repository_ref: session.repository_ref,
      session_ref: session.id,
      worker_id: command.worker_id
    })
  end

  defp binding!(policy_name, policy_digest, authority_digest) do
    {:ok, snapshot} =
      case Ryker.Settings.fetch() do
        {:ok, snapshot} -> {:ok, snapshot}
        {:error, :settings_not_initialized} -> Ryker.Settings.initialize("control-plane:local")
      end

    {:ok, _snapshot} =
      Ryker.Settings.put_policy_binding(
        %{
          authority_digest: authority_digest,
          policy_digest: policy_digest,
          policy_name: policy_name,
          purpose: :conversational,
          scope_kind: :installation,
          scope_ref: "",
          verified_by: :import
        },
        snapshot.installation.revision,
        "control-plane:local"
      )
  end

  defp create_episode!(suffix, turn_ref \\ nil) do
    command = create_kernel_episode!(suffix, turn_ref)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "work-read-only", String.duplicate("a", 64))

    command
  end

  defp create_kernel_episode!(suffix, turn_ref \\ nil) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "work:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: @now,
        turn_ref: turn_ref || "turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    command
  end

  defp submission!(context) do
    assert {:ok, submission} =
             Submission.new(
               context,
               "Continue the episode from its frozen state.",
               %{
                 "additionalProperties" => false,
                 "properties" => %{"message" => %{"type" => "string"}},
                 "required" => ["message"],
                 "type" => "object"
               },
               "work-final-live-v3"
             )

    submission
  end

  defp expire_lease!(turn_id) do
    {1, nil} =
      Repo.update_all(
        from(turn in Turn, where: turn.id == ^turn_id),
        set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]]
      )
  end
end
