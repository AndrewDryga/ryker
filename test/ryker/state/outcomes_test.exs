defmodule Ryker.State.OutcomesTest do
  use Ryker.DataCase, async: true

  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.State.{KnowledgeSnapshot, Outcomes, Record, Records}

  alias Ryker.Work.{
    Cancellation,
    Custody,
    DeliveryReceipt,
    Result,
    Submission,
    SubmissionBuilder
  }

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "completed and blocked episodes are recalled only inside their conversation" do
    completed = claim_episode!("completed", "private checkout latency incident", "conversation:A")

    assert {:ok, evidence} =
             Records.create(Records.token(completed.turn), "latency-evidence", "evidence", %{
               "claim_id" => "checkout-latency",
               "observation" => "Checkout p99 reached 3.4 seconds.",
               "source_name" => "Grafana",
               "source_type" => "monitoring",
               "target" => "payments-gateway"
             })

    assert {:ok, _assessment} =
             Records.create(
               Records.token(completed.turn),
               "latency-assessment",
               "alert_assessment",
               %{
                 "cause" => "The payments gateway connection pool was exhausted.",
                 "cause_claim_ids" => ["checkout-latency"],
                 "cause_status" => "identified",
                 "evidence_refs" => [evidence.ref],
                 "impact" => "Checkout p99 tripled.",
                 "immediate_action" => "Raised the pool ceiling to 200.",
                 "long_term_solution" => "Right-size the pool from measured concurrency.",
                 "verdict" => "confirmed_issue",
                 "verification" => "Checkout p99 held below 400ms for ten minutes."
               }
             )

    complete!(completed, "Checkout recovered after the pool ceiling changed.")

    blocked = claim_episode!("blocked", "worker is failing health checks", "conversation:A")

    assert {:ok, _finding} =
             Records.create(Records.token(blocked.turn), "blocked-finding", "finding", %{
               "status" => "unexplained",
               "what" => "The worker repeatedly exits before it becomes healthy."
             })

    block!(blocked, "Repository access is unavailable.")

    probe = claim_episode!("probe", "Is this related?", "conversation:A")
    outcomes = Outcomes.recall(probe.episode)

    assert Enum.map(outcomes, & &1["state"]) == ["blocked", "complete"]

    completed_outcome = Enum.find(outcomes, &(&1["episode_ref"] == completed.episode.id))
    assert completed_outcome["verified"]
    assert completed_outcome["trigger"]["text"] =~ "checkout latency"
    assert completed_outcome["result"]["message"] =~ "Checkout recovered"
    assert Enum.any?(completed_outcome["records"], &(&1["kind"] == "alert_assessment"))

    blocked_outcome = Enum.find(outcomes, &(&1["episode_ref"] == blocked.episode.id))
    refute blocked_outcome["verified"]
    assert blocked_outcome["blocker"] =~ "Repository access"

    assert {:ok, submission} = SubmissionBuilder.build(probe)
    assert submission["context"]["related_outcomes"] == outcomes
    assert submission["prompt"] =~ "payments gateway connection pool"

    other_room = claim_episode!("other-room", "What happened elsewhere?", "conversation:B")
    assert Outcomes.recall(other_room.episode) == []
  end

  test "cancelled and reopened episodes are not recalled as resolved outcomes" do
    cancelled = claim_episode!("cancelled", "cancel this investigation", "conversation:C")
    cancel!(cancelled)

    completed = claim_episode!("reopened", "initial lifecycle", "conversation:C")
    complete!(completed, "Initially resolved.")

    assert {:ok, _reopened} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: destination(completed),
                 episode_id: completed.episode.id,
                 episode_key: completed.episode.key,
                 native_input_id: "source:reopened:second",
                 occurred_at: DateTime.add(@now, 10, :second),
                 payload: %{"text" => "The symptom returned."},
                 turn_ref: "turn:reopened:second"
               })
             )

    probe = claim_episode!("cancelled-probe", "Recall prior work", "conversation:C")
    refs = MapSet.new(Outcomes.recall(probe.episode), & &1["episode_ref"])

    refute MapSet.member?(refs, cancelled.episode.id)
    refute MapSet.member?(refs, completed.episode.id)
  end

  test "frozen outcomes survive unrelated producer metadata and later record additions" do
    # A source-proven frozen result must not become stale because a sibling
    # episode receives another audit row or its diagnostics are updated.
    completed = claim_episode!("frozen-history", "Historical outcome", "conversation:frozen")
    complete!(completed, "The original retained result.")
    blocked = claim_episode!("frozen-blocked", "Blocked history", "conversation:frozen")
    block!(blocked, "The original retained blocker.")
    probe = claim_episode!("frozen-reader", "Recall prior work", "conversation:frozen", :briefing)
    submission = probe.turn.submission
    assert length(submission["context"]["related_outcomes"]) == 2
    assert :ok = KnowledgeSnapshot.authorize_submission(probe.episode, nil, submission)

    completed.episode
    |> Ecto.Changeset.change(updated_at: DateTime.add(DateTime.utc_now(), 1, :second))
    |> Repo.update!()

    blocked.turn
    |> Ecto.Changeset.change(last_error_detail: "Later unrelated diagnostic.")
    |> Repo.update!()

    # Structurally append an audit record, not a new captured model answer.
    payload = %{"observation" => "Later unrelated audit row."}

    Repo.insert!(%Record{
      id: Ecto.UUID.generate(),
      episode_id: completed.episode.id,
      turn_id: completed.turn.id,
      kind: "evidence",
      operation_id: "later-audit-row",
      payload: payload,
      payload_fingerprint: Ryker.CanonicalJSON.digest(payload),
      ref: "record:evidence:#{Ecto.UUID.generate()}",
      status: :open
    })

    assert :ok = KnowledgeSnapshot.authorize_submission(probe.episode, nil, submission)
    assert %{episode: %{state: :complete}} = complete!(probe, "Historical context remains valid.")
  end

  defp claim_episode!(suffix, text, conversation_ref, context \\ :fixture) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: conversation_ref,
          thread_ref: "thread:#{suffix}",
          transport: "slack"
        },
        episode_id: id,
        episode_key: "outcome:#{suffix}:#{id}",
        native_input_id: "source:#{suffix}:#{id}",
        occurred_at: @now,
        payload: %{"text" => text},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    bind_remote!(claim, context)
  end

  defp bind_remote!(claim, context) do
    submission = submission!(claim, context)

    assert {:ok, frozen} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert :ok = KnowledgeSnapshot.expose_submission(%{claim | turn: frozen})

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{claim.episode.id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               frozen.submit_generation,
               "coop-turn:#{claim.turn.id}"
             )

    %{claim | session: session, turn: turn}
  end

  defp submission!(claim, :briefing) do
    assert {:ok, submission} = SubmissionBuilder.build(claim)
    submission
  end

  defp submission!(claim, :fixture) do
    assert {:ok, submission} =
             Submission.new(
               %{"input" => claim.episode.key},
               "Investigate the frozen input.",
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

  defp complete!(claim, message) do
    candidate = ~s({"delivery":"reply","message":#{Jason.encode!(message)}})
    candidate_sha256 = digest(candidate)

    assert {:ok, _turn} =
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

    assert {:ok, result} = Result.new(:reply, %{"message" => message})

    assert {:ok, _intent} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               "validation:#{claim.turn.id}"
             )

    assert {:ok, delivery} = Custody.claim_next("delivery:#{claim.turn.id}", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               claim.episode.destination_transport,
               claim.episode.destination_conversation_ref,
               claim.episode.destination_thread_ref,
               "message:#{claim.turn.id}"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               delivery.lease_ref,
               receipt
             )

    settled
  end

  defp block!(claim, reason) do
    assert {:ok, _requested} =
             Custody.request_block(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               reason
             )

    assert {:ok, cancellation} = Custody.claim_next("worker:block:#{claim.turn.id}", 60)

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               claim.session.coop_session_id,
               claim.turn.coop_turn_id,
               "cancelled",
               Cancellation.operation_key(claim.turn.id, 1),
               "closed",
               "ryker:work:cancel-close:#{claim.turn.id}:g1"
             )

    assert {:ok, blocked} =
             Custody.settle_cancellation(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               cancellation.lease_ref,
               receipt
             )

    blocked
  end

  defp cancel!(claim) do
    cancel_ref = "cancel:#{claim.turn.id}"

    assert {:ok, _requested} =
             Custody.request_cancel(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               cancel_ref,
               "Stopped by the operator."
             )

    assert {:ok, cancellation} = Custody.claim_next("worker:cancel:#{claim.turn.id}", 60)

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               claim.session.coop_session_id,
               claim.turn.coop_turn_id,
               "cancelled",
               Cancellation.operation_key(claim.turn.id, 1),
               "closed",
               "ryker:work:cancel-close:#{claim.turn.id}:g1"
             )

    assert {:ok, cancelled} =
             Custody.settle_cancellation(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               cancellation.lease_ref,
               receipt
             )

    cancelled
  end

  defp destination(claim) do
    %{
      conversation_ref: claim.episode.destination_conversation_ref,
      thread_ref: claim.episode.destination_thread_ref,
      transport: claim.episode.destination_transport
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
