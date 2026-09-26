defmodule Ryker.Delivery.RoutingResponseCustodyTest do
  use Ryker.DataCase, async: true

  # Six async suites once shared T123:C456: sandbox transactions held the
  # conversation lock until test exit and cascaded into 15-second timeouts.
  # Keep this fixture's workspace distinct; production locks remain unchanged.

  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Delivery.{RoutingResponse, RoutingResponseCustody}
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.Input
  alias Ryker.Work.DeliveryReceipt

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "an accepted reaction becomes one durable leased delivery" do
    entry = record_input!("Ev-reaction-custody")
    context = context!(entry)
    reaction = reaction!("eyes")

    assert {:ok, applied} = Admission.commit(context, reaction, "decision:reaction-custody")
    assert applied.entry.status == :decided

    pending = Repo.get_by!(RoutingResponse, input_id: entry.id)
    assert pending.status == :pending
    assert pending.kind == :reaction
    assert pending.delivery_ref == "ingress-reaction:#{entry.id}"
    assert pending.decision_ref == "decision:reaction-custody"
    assert pending.document == %{"emoji_name" => "eyes"}
    assert pending.transport == "slack"
    assert pending.conversation_ref == "slack:TREACTIONCUSTODY:C456"
    assert pending.thread_ref == "1787832000.000100"
    assert pending.source_item_ref == "1787832001.000200"

    assert {:ok, duplicate} =
             Admission.commit(context, reaction, "decision:reaction-custody")

    assert duplicate.status == :duplicate
    assert Repo.aggregate(RoutingResponse, :count) == 1

    assert {:ok, claim} = RoutingResponseCustody.claim_next("delivery:reaction:1", 60)
    assert claim.response.id == pending.id
    assert claim.response.attempt_count == 1

    assert {:ok, request} = RoutingResponseCustody.request(claim.response)
    assert request.kind == :reaction
    assert request.ref == pending.delivery_ref
    assert request.document == %{"emoji_name" => "eyes"}

    assert {:ok, crossed} =
             DeliveryReceipt.new(
               pending.delivery_ref,
               "slack",
               "slack:TREACTIONCUSTODY:C999",
               pending.thread_ref,
               pending.source_item_ref
             )

    assert {:error, :routing_response_receipt_mismatch} =
             RoutingResponseCustody.confirm_delivery(
               pending.delivery_ref,
               claim.lease_ref,
               crossed
             )

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               pending.delivery_ref,
               pending.transport,
               pending.conversation_ref,
               pending.thread_ref,
               pending.source_item_ref
             )

    assert {:ok, delivered} =
             RoutingResponseCustody.confirm_delivery(
               pending.delivery_ref,
               claim.lease_ref,
               receipt
             )

    assert delivered.status == :delivered
    assert delivered.external_receipt == receipt
    assert delivered.delivered_at

    assert {:ok, exact_retry} =
             RoutingResponseCustody.confirm_delivery(
               pending.delivery_ref,
               claim.lease_ref,
               receipt
             )

    assert exact_retry.id == delivered.id

    assert {:ok, conflicting} =
             DeliveryReceipt.new(
               pending.delivery_ref,
               pending.transport,
               pending.conversation_ref,
               pending.thread_ref,
               "1787832001.000201"
             )

    assert {:error, :routing_response_receipt_conflict} =
             RoutingResponseCustody.confirm_delivery(
               pending.delivery_ref,
               claim.lease_ref,
               conflicting
             )

    assert {:ok, nil} = RoutingResponseCustody.claim_next("delivery:reaction:2", 60)
  end

  # Routing answers "hi" itself. Its words are a message of their own in the
  # thread, so the receipt names the new message, never the one answered; a
  # reaction's receipt check refused every quick reply ever sent.
  test "a quick reply is one durable message in the thread, settled by its own receipt" do
    entry = record_input!("Ev-quick-reply-custody")

    assert {:ok, applied} =
             Admission.commit(
               context!(entry),
               quick_reply!("Hi! What can I help with?"),
               "decision:quick-reply-custody"
             )

    assert applied.entry.decision_action == :quick_reply
    assert applied.episode == nil

    pending = Repo.get_by!(RoutingResponse, input_id: entry.id)
    assert pending.kind == :message
    assert pending.delivery_ref == "ingress-message:#{entry.id}"
    assert pending.document == %{"message" => "Hi! What can I help with?"}

    assert {:ok, claim} = RoutingResponseCustody.claim_next("delivery:routing:quick", 60)
    assert {:ok, request} = RoutingResponseCustody.request(claim.response)
    assert request.kind == :message
    assert request.source_item_ref == nil
    assert request.thread_ref == "1787832000.000100"
    assert request.conversation_ref == "slack:TREACTIONCUSTODY:C456"
    assert request.document == %{"message" => "Hi! What can I help with?"}

    assert {:ok, elsewhere} =
             DeliveryReceipt.new(
               pending.delivery_ref,
               pending.transport,
               pending.conversation_ref,
               "1787832000.999999",
               "1787832002.000300"
             )

    assert {:error, :routing_response_receipt_mismatch} =
             RoutingResponseCustody.confirm_delivery(
               pending.delivery_ref,
               claim.lease_ref,
               elsewhere
             )

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               pending.delivery_ref,
               pending.transport,
               pending.conversation_ref,
               pending.thread_ref,
               "1787832002.000300"
             )

    assert {:ok, delivered} =
             RoutingResponseCustody.confirm_delivery(
               pending.delivery_ref,
               claim.lease_ref,
               receipt
             )

    assert delivered.status == :delivered
    assert delivered.external_receipt["message_ref"] == "1787832002.000300"
  end

  test "a shadow reaction is audited as a decision but never enters delivery custody" do
    entry = record_input!("Ev-shadow-reaction", :shadow)

    assert {:ok, applied} =
             Admission.commit(context!(entry), reaction!("eyes"), "decision:shadow-reaction")

    assert applied.entry.execution_mode == :shadow
    assert applied.entry.decision_action == :react
    refute Repo.get_by(RoutingResponse, input_id: entry.id)
    assert Repo.aggregate(RoutingResponse, :count) == 0
  end

  test "a transient reaction error releases its lease for an exact retry" do
    entry = record_input!("Ev-reaction-retry")

    assert {:ok, _applied} =
             Admission.commit(context!(entry), reaction!("heart"), "decision:retry")

    assert {:ok, first} = RoutingResponseCustody.claim_next("delivery:reaction:first", 60)

    assert {:ok, deferred} =
             RoutingResponseCustody.defer(
               first.response.delivery_ref,
               first.lease_ref,
               1,
               "delivery_uncertain",
               "The provider response was lost."
             )

    assert deferred.status == :pending
    assert deferred.lease_ref == nil
    assert deferred.next_attempt_at
    assert {:ok, nil} = RoutingResponseCustody.claim_next("delivery:reaction:too-early", 60)

    Repo.update_all(RoutingResponse, set: [next_attempt_at: @now])

    assert {:ok, retry} = RoutingResponseCustody.claim_next("delivery:reaction:retry", 60)
    assert retry.response.id == first.response.id
    assert retry.response.attempt_count == 2
    refute retry.lease_ref == first.lease_ref
  end

  test "the current reaction owner can renew its opaque lease without spending an attempt" do
    entry = record_input!("Ev-reaction-renew")

    assert {:ok, _applied} =
             Admission.commit(context!(entry), reaction!("heart"), "decision:renew")

    assert {:ok, claim} = RoutingResponseCustody.claim_next("delivery:reaction:renew", 1)

    assert {:ok, renewed} =
             RoutingResponseCustody.renew(claim.response.delivery_ref, claim.lease_ref, 60)

    assert renewed.attempt_count == claim.response.attempt_count
    assert DateTime.compare(renewed.lease_expires_at, claim.response.lease_expires_at) == :gt

    assert {:error, :routing_response_lease_lost} =
             RoutingResponseCustody.renew(claim.response.delivery_ref, "wrong-lease", 60)
  end

  test "ignore creates no delivery outbox row" do
    entry = record_input!("Ev-ignore-custody")

    assert {:ok, ignored} =
             Admission.commit(context!(entry), ignore!(), "decision:ignore-custody")

    assert ignored.entry.status == :decided
    refute Repo.get_by(RoutingResponse, input_id: entry.id)
    assert Repo.aggregate(RoutingResponse, :count) == 0
  end

  test "invalid custody references are rejected before touching the queue" do
    assert {:error, {:invalid_routing_response, :worker_ref}} =
             RoutingResponseCustody.claim_next("", 60)

    assert {:error, {:invalid_routing_response, :request}} =
             RoutingResponseCustody.request(:invalid)
  end

  test "the database requires an emoji name in every durable reaction document" do
    entry = record_input!("Ev-reaction-document-constraint")

    assert {:ok, _applied} =
             Admission.commit(context!(entry), reaction!("eyes"), "decision:document-constraint")

    reaction = Repo.get_by!(RoutingResponse, input_id: entry.id)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE delivery_routing_responses SET document = '{}' WHERE id = $1", [
          Ecto.UUID.dump!(reaction.id)
        ])
      end

    assert error.postgres.constraint == "delivery_routing_response_document_valid"
  end

  defp record_input!(event_ref, execution_mode \\ :live) do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please acknowledge this input."},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: "1787832001.000200",
               occurred_at: @now,
               revision: 1,
               thread_ref: "1787832000.000100",
               workspace_ref: "TREACTIONCUSTODY"
             })

    assert {:ok, %{entry: entry, status: :recorded}} =
             Inbox.record(input, execution_mode: execution_mode)

    entry
  end

  defp context!(entry) do
    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: @now,
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8,
               lease_ref: nil
             )

    context
  end

  defp reaction!(emoji_name) do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => emoji_name},
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" => "Acknowledge the source item without starting work.",
               "work_class" => nil
             })

    decision
  end

  defp quick_reply!(message) do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "quick_reply",
               "episode_ref" => nil,
               "message" => message,
               "reaction" => nil,
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" => "A greeting needs a short answer, not work.",
               "work_class" => nil
             })

    decision
  end

  defp ignore! do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "ignore",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" => "No response is needed.",
               "work_class" => nil
             })

    decision
  end
end
