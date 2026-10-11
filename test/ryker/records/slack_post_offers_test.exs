defmodule Ryker.Records.SlackPostOffersTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Delivery.PlatformActionCustody
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Records
  alias Ryker.Records.SlackPostOffers
  alias Ryker.Slack.InteractionAudit
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Submission}

  @now ~U[2026-08-30 12:00:00.000000Z]

  # A cross-channel post delivered, but its source card stayed "confirmed"
  # forever because only the click queued a repaint (manual QA, 2026-10-11).
  test "delivery queues an idempotent source-card repaint with the exact post receipt" do
    fixture = delivered_offer!("receipt-repaint")

    {:ok, confirmed} =
      SlackPostOffers.confirm(confirmation(fixture, "slack:user:U123", "confirmed"))

    event_ref = "post-delivery:#{confirmed.action.id}"
    refute event_ref |> InteractionAudit.Query.by_event_ref() |> Repo.exists?()

    assert {:ok, %{action: action, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("post-delivery", 60)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               action.action_ref,
               "slack",
               action.conversation_ref,
               action.thread_ref,
               "1787833000.000400"
             )

    assert {:ok, delivered} =
             PlatformActionCustody.confirm_delivery(action.action_ref, lease_ref, receipt)

    assert audit = event_ref |> InteractionAudit.Query.by_event_ref() |> Repo.peek()
    assert audit.action_id == "post_delivery_receipt"
    assert audit.repaint_status == :pending
    assert audit.workspace_ref == "T123"
    assert audit.channel_ref == "C456"
    assert audit.thread_ref == fixture.receipt["thread_ref"]
    assert audit.message_ref == fixture.receipt["message_ref"]
    assert audit.actor_ref == "U123"

    assert {:ok, ^delivered} =
             PlatformActionCustody.confirm_delivery(action.action_ref, lease_ref, receipt)

    assert Repo.aggregate(InteractionAudit.Query.by_event_ref(event_ref), :count) == 1
    assert Repo.aggregate(PlatformAction, :count) == 1

    for changes <- [
          %{episode_id: Ecto.UUID.generate()},
          %{turn_id: Ecto.UUID.generate()},
          %{host_slot: "confirmed-post:not-an-id"},
          %{tool: :set_slack_reaction},
          %{transport: "github"}
        ] do
      id = Ecto.UUID.generate()
      other = delivered |> Map.merge(changes) |> Map.put(:id, id)

      assert Repo.transaction(fn ->
               Ryker.Slack.InteractionAudits.record_post_delivery_in_transaction(other)
             end) == {:ok, :ok}

      refute "post-delivery:#{id}" |> InteractionAudit.Query.by_event_ref() |> Repo.exists?()
    end

    delivered.turn_id
    |> Ryker.Work.Turn.Query.by_id()
    |> Repo.update_all(set: [operational_pruned_at: @now])

    id = Ecto.UUID.generate()

    assert Repo.transaction(fn ->
             Ryker.Slack.InteractionAudits.record_post_delivery_in_transaction(%{
               delivered
               | id: id
             })
           end) == {:ok, :ok}

    refute "post-delivery:#{id}" |> InteractionAudit.Query.by_event_ref() |> Repo.exists?()
  end

  test "only the exact requester confirmation enqueues one immutable additional Slack post" do
    fixture = delivered_offer!("authority")

    assert SlackPostOffers.confirm(confirmation(fixture, "slack:user:U999", "wrong-actor")) ==
             {:error, :slack_post_offer_actor_mismatch}

    crossed =
      fixture
      |> confirmation("slack:user:U123", "crossed")
      |> put_in([:target, :message_ref], "1787832999.999999")

    assert SlackPostOffers.confirm(crossed) ==
             {:error, :slack_post_offer_delivery_mismatch}

    assert {:ok, confirmed} =
             SlackPostOffers.confirm(confirmation(fixture, "slack:user:U123", "confirmed"))

    assert confirmed.status == :confirmed
    assert confirmed.record.status == :confirmed
    assert confirmed.record.confirmed_by_actor_ref == "slack:user:U123"
    assert %PlatformAction{} = confirmed.action
    assert confirmed.action.status == :pending
    assert confirmed.action.tool == :post_slack_message
    assert confirmed.action.kind == :message
    assert confirmed.action.transport == "slack"
    assert confirmed.action.conversation_ref == "slack:T123:C789"
    assert confirmed.action.thread_ref == "1787832888.000300"
    assert confirmed.action.document == %{"message" => "The deployment is healthy."}

    assert {:ok, duplicate} =
             SlackPostOffers.confirm(confirmation(fixture, "slack:user:U123", "confirmed"))

    assert duplicate.status == :duplicate
    assert duplicate.action.id == confirmed.action.id
    assert Repo.aggregate(PlatformAction, :count) == 1
  end

  defp delivered_offer!(suffix) do
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 actor_ref: "slack:user:U123",
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "1787832000.000100",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "slack-post-offer:#{suffix}:#{episode_id}",
                 native_input_id: "slack-message:post-offer:#{suffix}:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "turn:slack-post-offer:#{suffix}:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             WorkSessions.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:slack-post-offer:#{suffix}", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "offer", "slack_post_offer", %{
               "conversation_ref" => "slack:T123:C789",
               "destination_ref" => "slack-source:v1:T123:C789:thread:1787832888.000300",
               "instruction_ref" => "slack-source:v1:T123:C456:message:1787832000.000100",
               "message" => "The deployment is healthy.",
               "requested_by_actor_ref" => "slack:user:U123",
               "thread_ref" => "1787832888.000300",
               "transport" => "slack"
             })

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => transition.episode.id},
               "Offer the exact additional Slack post for confirmation.",
               %{"type" => "object"},
               "work-final-live-v3"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:slack-post-offer:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:slack-post-offer:#{suffix}"
             )

    candidate = ~s({"delivery":"reply","message":"Please confirm the exact additional post."})
    sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:reply, %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => "Please confirm the exact additional post.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => [record.ref],
                 "state" => "complete"
               }
             })

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:slack-post-offer:#{suffix}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:slack-post-offer:#{suffix}", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               "slack:T123:C456",
               "1787832000.000100",
               "1787832001.000200"
             )

    assert {:ok, _settled} =
             Custody.confirm_delivery(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{receipt: receipt, record: record}
  end

  defp confirmation(fixture, actor_ref, suffix) do
    %{
      actor_ref: actor_ref,
      confirmation_ref: "interaction:slack-post:#{suffix}",
      occurred_at: @now,
      record_ref: fixture.record.ref,
      target: %{
        conversation_ref: fixture.receipt["conversation_ref"],
        message_ref: fixture.receipt["message_ref"],
        thread_ref: fixture.receipt["thread_ref"],
        transport: fixture.receipt["transport"]
      }
    }
  end
end
