defmodule Ryker.Work.ResultCustodyTest do
  use Ryker.DataCase, async: true

  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.State.{EventSubscription, Records}

  alias Ryker.Work.{
    Custody,
    DeliveryReceipt,
    Result,
    Submission,
    SubmissionBuilder,
    ValidationIntent
  }

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "a Coop candidate is frozen before validation and replaced only by exact digest" do
    work = bound_turn!("candidate-cas")
    second_candidate = ~s({"delivery":"reply","message":"second"})
    second_sha = digest(second_candidate)
    first_sha = work.candidate_sha256

    assert {:ok, staged} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               nil,
               nil,
               work.candidate,
               work.candidate_sha256,
               work.candidate_attempt
             )

    assert staged.candidate == work.candidate
    assert staged.candidate_sha256 == work.candidate_sha256

    assert {:ok, exact_retry} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               nil,
               nil,
               work.candidate,
               work.candidate_sha256,
               work.candidate_attempt
             )

    assert exact_retry.id == staged.id

    assert {:error, {:work_candidate_conflict, ^first_sha}} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               String.duplicate("0", 64),
               work.candidate_attempt,
               second_candidate,
               second_sha,
               2
             )

    assert {:ok, replaced} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               work.candidate_sha256,
               work.candidate_attempt,
               second_candidate,
               second_sha,
               2
             )

    assert replaced.candidate == second_candidate
    assert replaced.candidate_sha256 == second_sha
    assert replaced.candidate_attempt == 2
    assert replaced.validation_generation == 1

    assert {:ok, prepared_rejection} =
             Custody.prepare_validation(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               replaced.candidate_sha256,
               replaced.candidate_attempt,
               {:reject, ["The final result must answer the current request."]},
               nil
             )

    assert prepared_rejection.validation_intent["verdict"] == "reject"
    assert byte_size(prepared_rejection.validation_intent_fingerprint) == 64

    assert {:ok, validation_retry} =
             Custody.advance_validation(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               replaced.candidate_sha256,
               replaced.candidate_attempt,
               replaced.validation_generation
             )

    assert validation_retry.validation_generation == 2

    assert {:ok, repeated_bytes_new_attempt} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               replaced.candidate_sha256,
               replaced.candidate_attempt,
               replaced.candidate,
               replaced.candidate_sha256,
               3
             )

    assert repeated_bytes_new_attempt.candidate == replaced.candidate
    assert repeated_bytes_new_attempt.candidate_attempt == 3
    assert repeated_bytes_new_attempt.validation_generation == 1
    assert repeated_bytes_new_attempt.validation_intent == nil
    assert repeated_bytes_new_attempt.validation_intent_fingerprint == nil

    assert {:error, {:invalid_work_custody, :candidate_sha256}} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               second_sha,
               2,
               second_candidate,
               String.duplicate("f", 64),
               2
             )
  end

  test "a candidate larger than Coop can return is rejected before persistence" do
    work = bound_turn!("candidate-bound")
    oversized = String.duplicate("x", 256 * 1_024 + 1)

    assert {:error, {:invalid_work_custody, :candidate}} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               nil,
               nil,
               oversized,
               digest(oversized),
               1
             )
  end

  test "the validation mutation and accepted result are rebuilt only from one frozen intent" do
    work = bound_turn!("validation-intent")
    stage_candidate!(work)
    first = result!(:reply, %{"message" => "First approved answer."})
    changed = result!(:reply, %{"message" => "Different answer after restart."})

    assert {:ok, prepared} = prepare_accept!(work, first)
    assert prepared.validation_intent["verdict"] == "accept"
    assert prepared.validation_intent_fingerprint != nil

    assert {:ok, exact_retry} = prepare_accept!(work, first)
    assert exact_retry.id == prepared.id

    assert {:error, {:work_validation_intent_conflict, stored_fingerprint}} =
             Custody.prepare_validation(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               work.candidate_sha256,
               work.candidate_attempt,
               :accept,
               changed
             )

    assert stored_fingerprint == prepared.validation_intent_fingerprint

    assert {:ok, accepted} = accept_prepared!(work)
    assert accepted.turn.delivery_document == first.delivery_document
    refute accepted.turn.delivery_document == changed.delivery_document
  end

  test "a visible result and delivery advance atomically and exact retries are harmless" do
    work = bound_turn!("visible-result")
    stage_candidate!(work)
    result = result!(:reply, %{"message" => "Investigation complete."})

    assert {:ok, accepted} = accept!(work, result)
    assert accepted.episode.owner_kind == :delivery
    assert accepted.episode.owner_ref == accepted.turn.delivery_ref
    assert accepted.turn.status == :delivery_pending
    assert accepted.turn.validation_receipt == "validation-receipt-1"
    assert accepted.turn.result_ref == "result:#{work.turn.id}"
    assert accepted.turn.delivery_ref == "delivery:#{work.turn.id}"
    assert accepted.turn.delivery_document == result.delivery_document
    assert accepted.turn.lease_ref == nil

    cancel =
      EpisodeFixtures.cancel_episode(%{
        cancel_ref: "cancel-during-delivery:#{work.turn.id}",
        expected_owner: %{kind: :delivery, ref: accepted.turn.delivery_ref}
      })

    cancel = %{cancel | episode_key: work.episode.key}

    assert Episodes.apply(cancel) == {:error, :delivery_must_settle_before_cancel}

    assert {:ok, accepted_retry} = accept!(work, result)
    assert accepted_retry.turn.id == accepted.turn.id
    assert accepted_retry.episode.owner_ref == accepted.episode.owner_ref

    assert {:ok, delivery_claim} =
             Custody.claim_next("worker:delivery", 60)

    assert delivery_claim.turn.id == work.turn.id
    assert delivery_claim.turn.delivery_attempt_count == 1
    receipt = receipt(work, "1787932801.000100")

    wrong_destination = %{receipt | "conversation_ref" => "slack:T-blitz:C-other"}

    assert {:error, :work_delivery_destination_mismatch} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery_claim.lease_ref,
               wrong_destination
             )

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    assert delivered.episode.state == :complete
    assert delivered.episode.owner_kind == nil
    assert delivered.turn.status == :settled
    assert delivered.turn.external_receipt == receipt
    assert delivered.turn.lease_ref == nil

    assert {:ok, delivered_retry} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    assert delivered_retry.turn.id == delivered.turn.id
  end

  test "a destination pause preserves and rearms an accepted unsent delivery" do
    work = bound_turn!("paused-delivery")
    stage_candidate!(work)
    result = result!(:reply, %{"message" => "Preserve this accepted answer."})
    assert {:ok, accepted} = accept!(work, result)
    pause_ref = "slack-incident-room:archived:CINCIDENT"

    assert {:ok, paused} =
             Custody.pause_destination(work.episode.id, work.episode.key, pause_ref)

    assert paused.status == :settled
    assert paused.turn.status == :blocked
    assert paused.turn.delivery_document == accepted.turn.delivery_document
    assert paused.turn.delivery_ref == accepted.turn.delivery_ref
    assert paused.turn.validation_receipt == accepted.turn.validation_receipt
    assert Custody.claim_next("worker:paused-delivery", 60, :delivery) == {:ok, nil}

    assert {:ok, resumed} =
             Custody.resume_destination(work.episode.id, work.episode.key, pause_ref)

    assert resumed.status == :settled
    assert resumed.turn.status == :delivery_pending
    assert resumed.turn.delivery_document == accepted.turn.delivery_document
    assert resumed.turn.delivery_ref == accepted.turn.delivery_ref

    assert {:ok, delivery} = Custody.claim_next("worker:resumed-delivery", 60, :delivery)
    assert delivery.turn.id == work.turn.id
  end

  test "new input cannot erase an accepted reply and continues in the same episode session" do
    work = bound_turn!("queued-after-result")
    stage_candidate!(work)
    result = result!(:reply, %{"message" => "First answer."})
    assert {:ok, accepted} = accept!(work, result)

    assert {:ok, delivery_claim} =
             Custody.claim_next("worker:delivery", 60)

    queued = queued_input(work, "after-result")
    assert {:ok, queued_transition} = Episodes.apply(queued)
    assert queued_transition.episode.owner_kind == :delivery
    assert queued_transition.episode.queued_input_refs != []

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt(work, "1787932802.000100")
             )

    assert delivered.episode.state == :working
    assert delivered.episode.owner_kind == :turn
    assert delivered.episode.owner_ref == "turn:after:#{work.turn.id}"
    assert delivered.episode.active_input_refs != []

    assert {:ok, continuation} = Custody.claim_next("worker:continuation", 60)
    assert continuation.episode.id == work.episode.id
    assert continuation.turn.id != work.turn.id
    assert continuation.turn.turn_ref == delivered.episode.owner_ref
    assert continuation.session.id == work.session.id
    assert continuation.session.coop_session_id == work.session.coop_session_id
    assert accepted.turn.delivery_ref == "delivery:#{work.turn.id}"
  end

  test "a delivered question enters its durable input wait" do
    work = bound_turn!("question-wait")
    stage_candidate!(work)

    continuation = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "question:#{work.turn.id}"
    }

    result = result!(:reply, %{"message" => "Which rollout should I inspect?"}, nil, continuation)
    assert {:ok, accepted} = accept!(work, result)
    assert accepted.turn.continuation == continuation

    assert {:ok, delivery_claim} =
             Custody.claim_next("worker:question-delivery", 60)

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt(work, "1787932803.000100")
             )

    assert delivered.episode.state == :waiting_for_input
    assert delivered.episode.owner_kind == :input
    assert delivered.episode.owner_ref == continuation["wait_ref"]
    assert delivered.episode.owner_deadline_at == nil
  end

  test "queued input wins over a requested wait after Slack accepts the reply" do
    work = bound_turn!("queued-question")
    stage_candidate!(work)

    continuation = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "question:#{work.turn.id}"
    }

    result = result!(:reply, %{"message" => "Which rollout should I inspect?"}, nil, continuation)
    assert {:ok, _accepted} = accept!(work, result)
    assert {:ok, _queued} = Episodes.apply(queued_input(work, "answer-before-receipt"))

    assert {:ok, delivery_claim} =
             Custody.claim_next("worker:queued-question-delivery", 60)

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt(work, "1787932804.000100")
             )

    assert delivered.episode.state == :working
    assert delivered.episode.owner_kind == :turn
    assert delivered.episode.owner_ref == "turn:after:#{work.turn.id}"
    assert delivered.episode.active_input_refs != []
  end

  test "an event wait is frozen in the delivery intent and expired delivery resumes immediately" do
    work = bound_turn!("event-wait")
    poll_after = ~U[2099-08-28 12:04:00.000000Z]
    deadline = ~U[2099-08-28 12:05:00.000000Z]

    assert {:ok, wait} =
             Records.create(Records.token(work.turn), "wait-for-rollout", "event_wait", %{
               "deadline_at" => DateTime.to_iso8601(deadline),
               "event_matcher" => %{
                 "cursor" => %{"revision" => "abc123"},
                 "match" => %{"revision" => "abc123", "state" => "healthy"},
                 "on_timeout" => "Report that rollout verification timed out.",
                 "poll_after" => DateTime.to_iso8601(poll_after),
                 "source_kind" => "github",
                 "type" => "source_event"
               },
               "kind" => "source_event",
               "verification" => "Verify the rollout is healthy."
             })

    stage_candidate!(work)

    continuation = %{
      "deadline_at" => deadline,
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => wait.ref
    }

    result =
      result!(:reply, %{"message" => "I will verify this after the rollout."}, nil, continuation)

    assert {:ok, accepted} = accept!(work, result)
    assert accepted.turn.continuation["deadline_at"] == DateTime.to_iso8601(deadline)

    assert {:ok, delivery_claim} =
             Custody.claim_next("worker:event-delivery", 60)

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt(work, "1787932805.000100")
             )

    assert delivered.episode.state == :waiting_for_event
    assert delivered.episode.owner_kind == :event
    assert delivered.episode.owner_ref == continuation["wait_ref"]
    assert delivered.episode.owner_deadline_at == deadline

    assert %EventSubscription{
             cursor: %{"revision" => "abc123"},
             deadline_at: ^deadline,
             poll_after: ^poll_after,
             source_kind: "github",
             status: :active
           } = Ryker.Repo.get_by!(EventSubscription, record_id: wait.id)
  end

  test "an event deadline elapsed during Slack delivery starts an immediate continuation" do
    work = bound_turn!("elapsed-event-wait")
    stage_candidate!(work)
    deadline = ~U[2099-08-28 12:05:00.000000Z]

    continuation = %{
      "deadline_at" => deadline,
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => "verification:#{work.turn.id}"
    }

    result = result!(:reply, %{"message" => "I will verify this shortly."}, nil, continuation)
    assert {:ok, accepted} = accept!(work, result)

    expired = %{
      continuation
      | "deadline_at" => DateTime.to_iso8601(~U[2020-08-28 12:05:00.000000Z])
    }

    accepted.turn
    |> Ecto.Changeset.change(continuation: expired)
    |> Ryker.Repo.update!()

    assert {:ok, delivery_claim} =
             Custody.claim_next("worker:elapsed-event-delivery", 60)

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt(work, "1787932806.000100")
             )

    assert delivered.turn.status == :settled
    assert delivered.turn.external_receipt["message_ref"] == "1787932806.000100"
    assert delivered.episode.state == :working
    assert delivered.episode.owner_kind == :turn
    assert delivered.episode.owner_ref == "turn:after:#{work.turn.id}"
    assert delivered.episode.active_input_refs == []

    assert {:ok, resumed} = Custody.claim_next("worker:elapsed-event-resume", 60, :work)
    assert {:ok, submission} = SubmissionBuilder.build(resumed)

    host_continuation = submission["context"]["continuity"]["host_continuation"]
    assert host_continuation["resume_cause"] == "deadline_elapsed"
    assert host_continuation["requested"] == expired
  end

  test "a silent wait accepted after its frozen deadline settles into immediate verification" do
    # A remote acceptance may finish after its deadline. Retrying that already
    # accepted candidate forever would strand the episode without any delivery.
    work = bound_turn!("silent-expired-wait")
    stage_candidate!(work)

    continuation = %{
      "deadline_at" => ~U[2099-08-28 12:05:00.000000Z],
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => "verification:#{work.turn.id}"
    }

    result = result!(:none, nil, "No material change to report.", continuation)
    assert {:ok, prepared} = prepare_accept!(work, result)

    # Advance only the frozen schedule across the acceptance boundary, without
    # a real sleep or altering the candidate/remote validation identity.
    expired =
      put_in(
        prepared.validation_intent,
        ["result", "continuation", "deadline_at"],
        "2020-08-28T12:05:00Z"
      )

    prepared
    |> Ecto.Changeset.change(
      validation_intent: expired,
      validation_intent_fingerprint: ValidationIntent.fingerprint(expired)
    )
    |> Ryker.Repo.update!()

    assert {:ok, accepted} = accept_prepared!(work)
    assert accepted.turn.status == :settled
    assert accepted.turn.delivery_ref == nil
    assert accepted.episode.state == :working
    assert accepted.episode.owner_ref == "turn:after:#{work.turn.id}"
    assert accepted.episode.active_input_refs == []
    assert {:ok, resumed} = Custody.claim_next("worker:silent-expired-resume", 60, :work)
    assert {:ok, submission} = SubmissionBuilder.build(resumed)

    assert submission["context"]["continuity"]["host_continuation"]["resume_cause"] ==
             "deadline_elapsed"
  end

  test "a deliberate no-delivery result advances already queued input without an outbox" do
    work = bound_turn!("silent-with-queue")
    stage_candidate!(work)
    assert {:ok, queued_transition} = Episodes.apply(queued_input(work, "before-result"))
    assert queued_transition.episode.queued_input_refs != []

    result = result!(:none, nil, "This is an exact duplicate lifecycle revision.")
    assert {:ok, accepted} = accept!(work, result)

    assert accepted.turn.status == :settled
    assert accepted.turn.delivery_ref == nil
    assert accepted.turn.delivery_document == nil
    assert accepted.turn.external_receipt == nil
    assert accepted.episode.state == :working
    assert accepted.episode.owner_kind == :turn
    assert accepted.episode.owner_ref == "turn:after:#{work.turn.id}"

    assert {:ok, continuation} = Custody.claim_next("worker:next", 60)
    assert continuation.session.id == work.session.id
    assert continuation.turn.turn_ref == accepted.episode.owner_ref
  end

  test "each receipt names its delivery while later turns may update the same message" do
    first = bound_turn!("receipt-owner-one")
    stage_candidate!(first)
    assert {:ok, _accepted} = accept!(first, result!(:reply, %{"message" => "First."}))
    assert {:ok, first_delivery} = Custody.claim_next("worker:first-delivery", 60)
    first_receipt = receipt(first, "1787932807.000100")

    assert {:ok, _settled} =
             Custody.confirm_delivery(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               first_delivery.lease_ref,
               first_receipt
             )

    second = bound_turn!("receipt-owner-two")
    stage_candidate!(second)
    assert {:ok, _accepted} = accept!(second, result!(:reply, %{"message" => "Second."}))
    assert {:ok, second_delivery} = Custody.claim_next("worker:second-delivery", 60)

    assert {:error, :work_delivery_receipt_mismatch} =
             Custody.confirm_delivery(
               second.episode.id,
               second.episode.key,
               second.turn.turn_ref,
               second_delivery.lease_ref,
               first_receipt
             )

    second_receipt = receipt(second, "1787932807.000100")

    assert {:ok, settled} =
             Custody.confirm_delivery(
               second.episode.id,
               second.episode.key,
               second.turn.turn_ref,
               second_delivery.lease_ref,
               second_receipt
             )

    assert settled.turn.external_receipt["message_ref"] == first_receipt["message_ref"]
    refute settled.turn.external_receipt["delivery_ref"] == first_receipt["delivery_ref"]
  end

  test "a candidate mismatch rolls the episode transition back" do
    work = bound_turn!("atomic-rollback")
    stage_candidate!(work)
    result = result!(:reply, %{"message" => "Must not be admitted."})
    candidate_sha256 = work.candidate_sha256

    prepare_accept!(work, result)

    assert {:error, {:work_candidate_conflict, ^candidate_sha256}} =
             Custody.accept_result(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               work.lease_ref,
               String.duplicate("0", 64),
               work.candidate_attempt,
               "validation-receipt-1"
             )

    assert {:ok, episode} = Episodes.fetch_by_key(work.episode.key)
    assert episode.owner_kind == :turn
    assert episode.owner_ref == work.turn.turn_ref
    assert Enum.map(Episodes.list_events(work.episode.key), & &1.kind) == [:input_admitted]
  end

  defp bound_turn!(suffix) do
    command = create_episode!(suffix)
    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 120)
    assert claim.episode.key == command.episode_key

    submission = submission!(claim)

    assert {:ok, _frozen} =
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
               claim.session.create_generation,
               "coop-session:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{suffix}"
             )

    candidate = ~s({"delivery":"reply","message":"Investigation complete."})

    %{
      candidate: candidate,
      candidate_attempt: 1,
      candidate_sha256: digest(candidate),
      episode: claim.episode,
      lease_ref: claim.lease_ref,
      session: session,
      turn: turn
    }
  end

  defp stage_candidate!(work) do
    assert {:ok, _turn} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               nil,
               nil,
               work.candidate,
               work.candidate_sha256,
               work.candidate_attempt
             )
  end

  defp accept!(work, result) do
    prepare_accept!(work, result)
    accept_prepared!(work)
  end

  defp prepare_accept!(work, result) do
    Custody.prepare_validation(
      work.episode.id,
      work.turn.turn_ref,
      work.lease_ref,
      work.candidate_sha256,
      work.candidate_attempt,
      :accept,
      result
    )
  end

  defp accept_prepared!(work) do
    Custody.accept_result(
      work.episode.id,
      work.episode.key,
      work.turn.turn_ref,
      work.lease_ref,
      work.candidate_sha256,
      work.candidate_attempt,
      "validation-receipt-1"
    )
  end

  defp create_episode!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-result:#{suffix}:#{id}",
        native_input_id: "source:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "work-read-only", String.duplicate("a", 64))

    command
  end

  defp queued_input(work, suffix) do
    EpisodeFixtures.admit_input(%{
      destination: %{
        conversation_ref: work.episode.destination_conversation_ref,
        thread_ref: work.episode.destination_thread_ref,
        transport: work.episode.destination_transport
      },
      episode_id: work.episode.id,
      episode_key: work.episode.key,
      native_input_id: "source:queued:#{suffix}:#{Ecto.UUID.generate()}",
      occurred_at: DateTime.add(@now, 1, :second),
      payload: %{"text" => "Follow-up"},
      turn_ref: "unused:#{Ecto.UUID.generate()}"
    })
  end

  defp submission!(claim) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => claim.episode.id, "turn_ref" => claim.turn.turn_ref},
               "Continue from the frozen episode state.",
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

  defp result!(delivery, document, reason \\ nil, continuation \\ %{"kind" => "complete"}) do
    assert {:ok, result} = Result.new(delivery, document, reason, continuation)
    result
  end

  defp receipt(work, message_ref) do
    assert {:ok, receipt} =
             DeliveryReceipt.new(
               "delivery:#{work.turn.id}",
               work.episode.destination_transport,
               work.episode.destination_conversation_ref,
               work.episode.destination_thread_ref,
               message_ref
             )

    receipt
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
