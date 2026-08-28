defmodule Responder.Work.CustodyTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.{Cancellation, Custody, Submission, Turn, TurnChangeset}

  @now ~U[2026-08-28 12:00:00.000000Z]

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
        from(episode in Responder.Episodes.Episode,
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
    command = create_episode!("policy-default-evolves")

    assert {:ok, original} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only-v2",
               String.duplicate("b", 64)
             )

    assert original.policy == "work-read-only"

    assert {:ok, claim} = Custody.claim_next("worker:new-default", 60)
    assert claim.session.id == original.id
    assert claim.session.policy == "work-read-only"
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
               "responder:work:create:#{claim.session.id}:g#{claim.session.create_generation}",
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
      maximum_block_ms: 1_000,
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
               "work-final-v1"
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
