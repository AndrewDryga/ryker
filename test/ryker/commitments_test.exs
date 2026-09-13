defmodule Ryker.CommitmentsTest do
  use Ryker.DataCase, async: false

  alias Ryker.Commitments
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.State.Records
  alias Ryker.Work.{Cancellation, Custody}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @policy_digest String.duplicate("a", 64)

  test "one turn token projects every durable commitment state in its destination" do
    source = work_claim!("source")
    token = Records.token(source.claim.turn)

    assert {:ok, _progress} =
             Records.create(token, "commitment-progress", "progress", %{
               "next_due_at" => "2026-08-28T12:01:00.000000Z",
               "phase" => "verifying",
               "summary" => "A promised update is overdue."
             })

    assert {:ok, _required_goal} =
             Records.create(token, "commitment-goal-open", "goal", goal("open-goal", true))

    assert {:ok, _completed_goal} =
             Records.create(
               token,
               "commitment-goal-complete",
               "goal",
               goal("completed-goal", true)
             )

    assert {:ok, _goal_state} =
             Records.create(token, "commitment-goal-state", "goal_state", %{
               "detail" => "The check passed.",
               "goal_id" => "completed-goal",
               "state" => "completed"
             })

    working = work_claim!("working")
    queued = work_claim!("queued")

    assert {:ok, _queued} =
             Custody.yield_progress(
               queued.episode.id,
               queued.claim.turn.turn_ref,
               queued.claim.lease_ref,
               60
             )

    blocked = work_claim!("blocked")
    block!(blocked)

    stopping = work_claim!("stopping")

    assert {:ok, %{status: :pending}} =
             Custody.request_block(
               stopping.episode.id,
               stopping.episode.key,
               stopping.claim.turn.turn_ref,
               stopping.claim.lease_ref,
               "Remote cleanup is still being reconciled."
             )

    waiting_input = started!("waiting-input")

    assert {:ok, _waiting_input} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: waiting_input.episode.key,
                 expected_turn_ref: waiting_input.episode.owner_ref,
                 wait_ref: "question:#{waiting_input.episode.id}"
               })
             )

    waiting_event = started!("waiting-event")

    assert {:ok, _waiting_event} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: DateTime.add(@now, 60, :second),
                 episode_key: waiting_event.episode.key,
                 expected_turn_ref: waiting_event.episode.owner_ref,
                 kind: :event,
                 wait_ref: "event:#{waiting_event.episode.id}"
               })
             )

    delivery = started!("delivery")

    assert {:ok, _delivery} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 delivery_ref: "delivery:#{delivery.episode.id}",
                 episode_key: delivery.episode.key,
                 expected_turn_ref: delivery.episode.owner_ref,
                 result_ref: "result:#{delivery.episode.id}"
               })
             )

    cancelled = started!("cancelled")

    assert {:ok, _cancelled} =
             Episodes.apply(
               EpisodeFixtures.cancel_episode(%{
                 cancel_ref: "cancel:#{cancelled.episode.id}",
                 episode_key: cancelled.episode.key,
                 expected_owner: %{kind: :turn, ref: cancelled.episode.owner_ref}
               })
             )

    assert {:ok, commitments} = Commitments.list_for_token(token, limit: 25)
    by_ref = Map.new(commitments, &{&1["episode_ref"], &1})

    assert by_ref[source.episode.key]["status"] == "working"
    assert by_ref[source.episode.key]["next_action"] == "start_work"
    assert by_ref[source.episode.key]["overdue"]

    assert by_ref[source.episode.key]["required_goals"] == [
             %{
               "id" => "open-goal",
               "requested_outcome" => "Complete open-goal",
               "state" => "ready"
             }
           ]

    assert by_ref[working.episode.key]["status"] == "working"
    assert by_ref[queued.episode.key]["status"] == "queued"
    assert by_ref[blocked.episode.key]["status"] == "blocked"
    assert by_ref[blocked.episode.key]["next_action"] == "operator_recovery"
    assert by_ref[stopping.episode.key]["status"] == "finishing"
    assert by_ref[stopping.episode.key]["next_action"] == "reconcile_stop"
    assert by_ref[waiting_input.episode.key]["status"] == "blocked"
    assert by_ref[waiting_input.episode.key]["next_action"] == "operator_input"
    assert by_ref[waiting_event.episode.key]["status"] == "waiting"
    assert by_ref[waiting_event.episode.key]["next_action"] == "external_event"
    assert by_ref[waiting_event.episode.key]["overdue"]
    assert by_ref[delivery.episode.key]["status"] == "finishing"
    assert by_ref[delivery.episode.key]["next_action"] == "deliver_result"
    assert by_ref[cancelled.episode.key]["status"] == "cancelled"

    assert Commitments.list_destination(source.episode, 1) |> length() == 1
    assert Commitments.list_destination(:invalid, 25) == []
  end

  test "commitment reads reject stale capabilities and ambiguous bounds" do
    work = work_claim!("authorization")
    token = Records.token(work.claim.turn)

    assert Commitments.list_for_token("invalid") == {:error, :commitment_unauthorized}
    assert Commitments.list_for_token("state:not-a-uuid") == {:error, :commitment_unauthorized}
    assert Commitments.list_for_token(token, limit: 0) == {:error, :commitment_unauthorized}

    assert Commitments.list_for_token(token, unknown: true) ==
             {:error, :commitment_unauthorized}

    block!(work)

    assert Commitments.list_for_token(token) == {:error, :commitment_unauthorized}
  end

  defp started!(suffix) do
    id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "thread:commitment:#{suffix}:#{id}",
                   transport: "slack"
                 },
                 episode_id: id,
                 episode_key: "commitment:#{suffix}:#{id}",
                 native_input_id: "source:commitment:#{suffix}:#{id}",
                 occurred_at: @now,
                 turn_ref: "turn:commitment:#{suffix}:#{id}"
               })
             )

    transition
  end

  defp work_claim!(suffix) do
    transition = started!(suffix)

    assert {:ok, session} =
             Custody.pin_episode(transition.episode.id, "policy:read", @policy_digest)

    assert {:ok, claim} = Custody.claim_next("commitment-worker:#{suffix}", 60, :work)
    assert claim.episode.id == transition.episode.id
    %{claim: claim, episode: transition.episode, session: session}
  end

  defp block!(work) do
    assert {:ok, %{status: :pending}} =
             Custody.request_block(
               work.episode.id,
               work.episode.key,
               work.claim.turn.turn_ref,
               work.claim.lease_ref,
               "Operator recovery is required."
             )

    assert {:ok, claim} = Custody.claim_next("commitment-worker:block-cleanup", 60, :work)

    assert {:ok, receipt} =
             Cancellation.absent_receipt(
               "ryker:work:create:#{work.session.id}:g#{work.session.create_generation}",
               nil,
               nil,
               nil,
               nil
             )

    assert {:ok, %{turn: %{status: :blocked}}} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.claim.turn.turn_ref,
               claim.lease_ref,
               receipt
             )
  end

  defp goal(id, required) do
    %{
      "authority" => "read_only",
      "completion_contract" => "The requested check is complete.",
      "id" => id,
      "kind" => "check",
      "prerequisite_goal_ids" => [],
      "read_only_repositories" => [],
      "requested_outcome" => "Complete #{id}",
      "required" => required,
      "stage" => "implementation",
      "writable_repository" => nil
    }
  end
end
