defmodule Responder.Work.CancellationTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.{Cancellation, Custody, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "a bound Coop turn is cancelled remotely before its episode can be cancelled" do
    work = bound_turn!("cancel")
    cancel_ref = "cancel:#{work.turn.id}"

    command =
      EpisodeFixtures.cancel_episode(%{
        cancel_ref: cancel_ref,
        episode_key: work.episode.key,
        expected_owner: %{kind: :turn, ref: work.turn.turn_ref},
        reason: "Stopped by the operator."
      })

    assert Episodes.apply(command) == {:error, :work_cancellation_required}

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               cancel_ref,
               "Stopped by the operator."
             )

    assert requested.status == :pending
    assert requested.episode.owner_kind == :turn
    assert requested.turn.status == :cancel_pending
    assert requested.turn.lease_ref == nil
    assert requested.turn.cancellation_intent["action"] == "cancel"

    assert {:ok, claim} = Custody.claim_next("worker:cancel", 60)
    assert claim.turn.id == work.turn.id
    assert claim.turn.status == :cancel_pending

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               work.session.coop_session_id,
               work.turn.coop_turn_id,
               "cancelled",
               Cancellation.operation_key(work.turn.id, 1),
               "closed",
               "responder:work:cancel-close:#{work.turn.id}:g1"
             )

    assert {:ok, settled} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    assert settled.episode.state == :cancelled
    assert settled.episode.owner_kind == nil
    assert settled.turn.status == :superseded
    assert settled.turn.cancellation_receipt == receipt
    assert settled.turn.cancelled_at != nil

    assert {:ok, retry} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    assert retry.turn.id == settled.turn.id
  end

  test "a proven remote cancellation transfers ownership without abandoning the old turn" do
    work = bound_turn!("transfer")
    new_turn_ref = "turn:replacement:#{work.turn.id}"

    assert {:ok, requested} =
             Custody.request_transfer(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               new_turn_ref,
               "transfer:#{work.turn.id}"
             )

    assert requested.turn.status == :cancel_pending
    assert requested.turn.cancellation_intent["action"] == "transfer"

    assert {:ok, claim} = Custody.claim_next("worker:transfer-cancel", 60)

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               work.session.coop_session_id,
               work.turn.coop_turn_id,
               "cancelled",
               Cancellation.operation_key(work.turn.id, 1),
               "open",
               nil
             )

    assert {:ok, settled} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    assert settled.episode.state == :working
    assert settled.episode.owner_kind == :turn
    assert settled.episode.owner_ref == new_turn_ref
    assert settled.turn.status == :superseded

    assert {:ok, replacement} = Custody.claim_next("worker:replacement", 60)
    assert replacement.turn.turn_ref == new_turn_ref
    assert replacement.session.id == work.session.id
  end

  test "an exact pending transfer retry preserves the cancellation worker lease" do
    work = bound_turn!("pending-transfer-retry")
    new_turn_ref = "turn:replacement:#{work.turn.id}"
    transfer_ref = "transfer:#{work.turn.id}"

    assert {:ok, _requested} =
             Custody.request_transfer(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               new_turn_ref,
               transfer_ref
             )

    assert {:ok, cleanup} = Custody.claim_next("worker:pending-transfer-retry", 60, :work)
    assert is_binary(cleanup.lease_ref)

    assert {:ok, retried} =
             Custody.request_transfer(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               new_turn_ref,
               transfer_ref
             )

    assert retried.status == :pending
    assert retried.turn.lease_ref == cleanup.lease_ref

    assert {:ok, renewed} =
             Custody.renew(
               work.episode.id,
               work.turn.turn_ref,
               cleanup.lease_ref,
               60
             )

    assert renewed.lease_ref == cleanup.lease_ref
  end

  test "an exact settled transfer retry survives creation of its target turn" do
    work = bound_turn!("settled-transfer-retry")
    new_turn_ref = "turn:replacement:#{work.turn.id}"
    transfer_ref = "transfer:#{work.turn.id}"

    assert {:ok, _requested} =
             Custody.request_transfer(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               new_turn_ref,
               transfer_ref
             )

    assert {:ok, cleanup} = Custody.claim_next("worker:settled-transfer-retry", 60, :work)

    assert {:ok, settled} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               cleanup.lease_ref,
               terminal_receipt!(work, "open")
             )

    assert settled.episode.owner_ref == new_turn_ref
    assert {:ok, replacement} = Custody.claim_next("worker:settled-transfer-target", 60, :work)
    assert replacement.turn.turn_ref == new_turn_ref

    assert {:ok, retried} =
             Custody.request_transfer(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               new_turn_ref,
               transfer_ref
             )

    assert retried.status == :settled
    assert retried.episode.owner_ref == new_turn_ref
    assert retried.turn.status == :superseded
  end

  test "cancellation before a remote Coop turn exists settles locally without a cancel mutation" do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-cancel:local:#{id}",
        native_input_id: "source:cancel-local:#{id}",
        occurred_at: @now,
        turn_ref: "turn:cancel-local:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, settled} =
             Custody.request_cancel(
               id,
               command.episode_key,
               command.turn_ref,
               "cancel:local:#{id}",
               "Stopped before execution began."
             )

    assert settled.status == :settled
    assert settled.episode.state == :cancelled
    assert settled.turn == nil
  end

  test "an unbound claimed turn still requires Work cancellation reconciliation" do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-cancel:unbound:#{id}",
        native_input_id: "source:cancel-unbound:#{id}",
        occurred_at: @now,
        turn_ref: "turn:cancel-unbound:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    assert {:ok, _session} = Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))
    assert {:ok, _claim} = Custody.claim_next("worker:cancel-unbound", 60)

    cancel =
      EpisodeFixtures.cancel_episode(%{
        cancel_ref: "cancel:unbound:#{id}",
        episode_key: command.episode_key,
        expected_owner: %{kind: :turn, ref: command.turn_ref},
        reason: "Stopped while remote admission may be in flight."
      })

    assert Episodes.apply(cancel) == {:error, :work_cancellation_required}
  end

  test "operator cancellation supersedes an internal stop disposition in either order" do
    pending = bound_turn!("operator-overrides-pending-block")

    assert {:ok, blocked_request} =
             Custody.request_block(
               pending.episode.id,
               pending.episode.key,
               pending.turn.turn_ref,
               pending.lease_ref,
               "The executor cannot safely continue."
             )

    assert blocked_request.turn.cancellation_intent["action"] == "block"

    assert {:ok, cancelled_request} =
             Custody.request_cancel(
               pending.episode.id,
               pending.episode.key,
               pending.turn.turn_ref,
               "cancel:override:#{pending.turn.id}",
               "The operator chose Stop."
             )

    assert cancelled_request.turn.status == :cancel_pending
    assert cancelled_request.turn.cancellation_intent["action"] == "cancel"

    assert Custody.request_block(
             pending.episode.id,
             pending.episode.key,
             pending.turn.turn_ref,
             pending.lease_ref,
             "A stale internal error must not override Stop."
           ) == {:error, :work_lease_lost}

    assert {:ok, pending_cancel_claim} = Custody.claim_next("worker:pending-override", 60)
    pending_receipt = terminal_receipt!(pending, "closed")

    assert {:ok, _pending_settled} =
             Custody.settle_cancellation(
               pending.episode.id,
               pending.episode.key,
               pending.turn.turn_ref,
               pending_cancel_claim.lease_ref,
               pending_receipt
             )

    settled = bound_turn!("operator-overrides-settled-block")

    assert {:ok, _requested} =
             Custody.request_block(
               settled.episode.id,
               settled.episode.key,
               settled.turn.turn_ref,
               settled.lease_ref,
               "The executor cannot safely continue."
             )

    assert {:ok, claim} = Custody.claim_next("worker:settle-block", 60)
    receipt = terminal_receipt!(settled, "closed")

    assert {:ok, blocked} =
             Custody.settle_cancellation(
               settled.episode.id,
               settled.episode.key,
               settled.turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    assert blocked.turn.status == :blocked
    assert blocked.episode.owner_ref == settled.turn.turn_ref

    assert {:ok, overridden} =
             Custody.request_cancel(
               settled.episode.id,
               settled.episode.key,
               settled.turn.turn_ref,
               "cancel:settled-override:#{settled.turn.id}",
               "The operator chose Stop after cleanup began."
             )

    assert overridden.episode.state == :cancelled
    assert overridden.turn.status == :superseded
    assert overridden.turn.cancellation_intent["action"] == "cancel"
  end

  test "owner transfer rejects the current or any historical Work turn identity" do
    first = bound_turn!("transfer-target-identity")

    assert Custody.request_transfer(
             first.episode.id,
             first.episode.key,
             first.turn.turn_ref,
             first.turn.turn_ref,
             "transfer:same:#{first.turn.id}"
           ) == {:error, :work_transfer_target_conflict}

    next_ref = "turn:replacement:#{first.turn.id}"

    assert {:ok, _requested} =
             Custody.request_transfer(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               next_ref,
               "transfer:forward:#{first.turn.id}"
             )

    assert {:ok, cancel_claim} = Custody.claim_next("worker:transfer-target", 60)
    receipt = terminal_receipt!(first, "open")

    assert {:ok, _settled} =
             Custody.settle_cancellation(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               cancel_claim.lease_ref,
               receipt
             )

    assert {:ok, second} = Custody.claim_next("worker:replacement-target", 60)
    assert second.turn.turn_ref == next_ref

    assert Custody.request_transfer(
             second.episode.id,
             second.episode.key,
             second.turn.turn_ref,
             first.turn.turn_ref,
             "transfer:backward:#{second.turn.id}"
           ) == {:error, :work_transfer_target_conflict}
  end

  test "a user correction rearms a remotely settled blocked turn" do
    work = bound_turn!("resume-blocked")

    assert {:ok, _requested} =
             Custody.request_block(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               work.lease_ref,
               "The executor cannot continue without a corrected input."
             )

    assert {:ok, stop_claim} = Custody.claim_next("worker:stop-blocked", 60)
    receipt = terminal_receipt!(work, "closed")

    assert {:ok, blocked} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               stop_claim.lease_ref,
               receipt
             )

    assert blocked.turn.status == :blocked

    feedback =
      EpisodeFixtures.admit_input(%{
        episode_id: work.episode.id,
        episode_key: work.episode.key,
        native_input_id: "source:resume-blocked:feedback",
        occurred_at: DateTime.add(@now, 1, :second),
        turn_ref: "turn:must-not-bypass-blocked-custody"
      })

    assert {:ok, queued} = Episodes.apply(feedback)
    assert queued.episode.owner_ref == work.turn.turn_ref
    assert queued.episode.queued_input_refs != []

    assert {:ok, resumed} =
             Repo.transaction(fn ->
               assert {:ok, resumed} =
                        Custody.resume_blocked_in_transaction(
                          queued.episode,
                          Command.dedupe_key(feedback)
                        )

               resumed
             end)

    assert resumed.owner_ref =~ "turn:resume-blocked:#{work.turn.id}:v"
    assert resumed.queued_input_refs == []
    assert length(resumed.active_input_refs) == 2

    assert {:ok, replacement} = Custody.claim_next("worker:resumed-blocked", 60)
    assert replacement.episode.owner_ref == resumed.owner_ref
    assert replacement.turn.turn_ref == resumed.owner_ref
    assert replacement.session.generation == work.session.generation + 1

    replacement = bind_claimed_turn!(replacement, "resume-blocked-second-correction")

    assert {:ok, _requested} =
             Custody.request_block(
               replacement.episode.id,
               replacement.episode.key,
               replacement.turn.turn_ref,
               replacement.lease_ref,
               "The first correction was insufficient."
             )

    assert {:ok, second_stop} = Custody.claim_next("worker:stop-blocked-again", 60, :work)

    assert {:ok, _blocked_again} =
             Custody.settle_cancellation(
               replacement.episode.id,
               replacement.episode.key,
               replacement.turn.turn_ref,
               second_stop.lease_ref,
               terminal_receipt!(replacement, "closed")
             )

    second_feedback =
      EpisodeFixtures.admit_input(%{
        episode_id: work.episode.id,
        episode_key: work.episode.key,
        native_input_id: "source:resume-blocked:second-feedback",
        occurred_at: DateTime.add(@now, 2, :second),
        turn_ref: "turn:must-use-second-correction"
      })

    assert {:ok, second_queued} = Episodes.apply(second_feedback)
    second_feedback_ref = Command.dedupe_key(second_feedback)

    assert {:ok, resumed_again} =
             Repo.transaction(fn ->
               assert {:ok, resumed_again} =
                        Custody.resume_blocked_in_transaction(
                          second_queued.episode,
                          second_feedback_ref
                        )

               resumed_again
             end)

    assert resumed_again.active_input_refs == [
             hd(work.episode.active_input_refs),
             second_feedback_ref
           ]

    refute Command.dedupe_key(feedback) in resumed_again.active_input_refs
    assert resumed_again.queued_input_refs == []
  end

  test "cancellation and close retries retain their first exact session revision" do
    work = bound_turn!("frozen-cancellation-revisions")

    assert {:ok, _requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:frozen-revisions:#{work.turn.id}",
               "Stop with exact idempotent request bodies."
             )

    assert {:ok, claim} = Custody.claim_next("worker:frozen-cancellation-revisions", 60, :work)

    assert {:ok, first_cancel} =
             Custody.freeze_cancellation_revision(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               :cancel_turn,
               3
             )

    assert first_cancel.cancel_expected_revision == 3

    assert {:ok, retried_cancel} =
             Custody.freeze_cancellation_revision(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               :cancel_turn,
               9
             )

    assert retried_cancel.cancel_expected_revision == 3

    assert {:ok, first_close} =
             Custody.freeze_cancellation_revision(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               :close_session,
               4
             )

    assert first_close.close_expected_revision == 4

    assert {:ok, retried_close} =
             Custody.freeze_cancellation_revision(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               :close_session,
               10
             )

    assert retried_close.close_expected_revision == 4
  end

  defp bound_turn!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-cancel:#{suffix}:#{id}",
        native_input_id: "source:cancel:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: "turn:cancel:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)

    assert {:ok, submission} =
             Submission.new(
               %{"request" => suffix},
               "Handle the request.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(id, command.turn_ref, claim.lease_ref, submission)

    assert {:ok, session} =
             Custody.bind_session(
               id,
               command.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               id,
               command.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{id}"
             )

    %{episode: claim.episode, lease_ref: claim.lease_ref, session: session, turn: turn}
  end

  defp bind_claimed_turn!(claim, suffix) do
    assert {:ok, submission} =
             Submission.new(
               %{"request" => suffix},
               "Handle the corrected request.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
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
               "coop-session:#{claim.episode.id}:g#{claim.session.generation}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{claim.episode.id}:g#{session.generation}"
             )

    %{episode: claim.episode, lease_ref: claim.lease_ref, session: session, turn: turn}
  end

  defp terminal_receipt!(work, session_state) do
    close_ref =
      if session_state == "open",
        do: nil,
        else: "responder:work:cancel-close:#{work.turn.id}:g1"

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               work.session.coop_session_id,
               work.turn.coop_turn_id,
               "cancelled",
               Cancellation.operation_key(work.turn.id, 1),
               session_state,
               close_ref
             )

    receipt
  end
end
