defmodule Responder.Delivery.ReactionCustodyTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission
  alias Responder.Admission.Decision
  alias Responder.Delivery.{Reaction, ReactionCustody}
  alias Responder.Ingress.Inbox
  alias Responder.Slack.Input
  alias Responder.Work.DeliveryReceipt

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "an accepted reaction becomes one durable leased delivery" do
    entry = record_input!("Ev-reaction-custody")
    context = context!(entry)
    reaction = reaction!("eyes")

    assert {:ok, applied} = Admission.commit(context, reaction, "decision:reaction-custody")
    assert applied.entry.status == :decided

    assert {:ok, pending} = ReactionCustody.fetch_by_input(entry.id)
    assert pending.status == :pending
    assert pending.delivery_ref == "ingress-reaction:#{entry.id}"
    assert pending.decision_ref == "decision:reaction-custody"
    assert pending.document == %{"emoji_name" => "eyes"}
    assert pending.transport == "slack"
    assert pending.conversation_ref == "slack:T123:C456"
    assert pending.thread_ref == "1787832000.000100"
    assert pending.source_item_ref == "1787832001.000200"

    assert {:ok, duplicate} =
             Admission.commit(context, reaction, "decision:reaction-custody")

    assert duplicate.status == :duplicate
    assert Repo.aggregate(Reaction, :count) == 1

    assert {:ok, claim} = ReactionCustody.claim_next("delivery:reaction:1", 60)
    assert claim.reaction.id == pending.id
    assert claim.reaction.attempt_count == 1

    assert {:ok, request} = ReactionCustody.request(claim.reaction)
    assert request.kind == :reaction
    assert request.ref == pending.delivery_ref
    assert request.document == %{"emoji_name" => "eyes"}

    assert {:ok, crossed} =
             DeliveryReceipt.new(
               pending.delivery_ref,
               "slack",
               "slack:T123:C999",
               pending.thread_ref,
               pending.source_item_ref
             )

    assert {:error, :delivery_reaction_receipt_mismatch} =
             ReactionCustody.confirm_delivery(
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
             ReactionCustody.confirm_delivery(
               pending.delivery_ref,
               claim.lease_ref,
               receipt
             )

    assert delivered.status == :delivered
    assert delivered.external_receipt == receipt
    assert delivered.delivered_at

    assert {:ok, exact_retry} =
             ReactionCustody.confirm_delivery(
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

    assert {:error, :delivery_reaction_receipt_conflict} =
             ReactionCustody.confirm_delivery(
               pending.delivery_ref,
               claim.lease_ref,
               conflicting
             )

    assert {:ok, nil} = ReactionCustody.claim_next("delivery:reaction:2", 60)
  end

  test "a shadow reaction is audited as a decision but never enters delivery custody" do
    entry = record_input!("Ev-shadow-reaction", :shadow)

    assert {:ok, applied} =
             Admission.commit(context!(entry), reaction!("eyes"), "decision:shadow-reaction")

    assert applied.entry.execution_mode == :shadow
    assert applied.entry.decision_action == :react
    assert :error = ReactionCustody.fetch_by_input(entry.id)
    assert Repo.aggregate(Reaction, :count) == 0
  end

  test "a transient reaction error releases its lease for an exact retry" do
    entry = record_input!("Ev-reaction-retry")

    assert {:ok, _applied} =
             Admission.commit(context!(entry), reaction!("heart"), "decision:retry")

    assert {:ok, first} = ReactionCustody.claim_next("delivery:reaction:first", 60)

    assert {:ok, deferred} =
             ReactionCustody.defer(
               first.reaction.delivery_ref,
               first.lease_ref,
               1,
               "delivery_uncertain",
               "The provider response was lost."
             )

    assert deferred.status == :pending
    assert deferred.lease_ref == nil
    assert deferred.next_attempt_at
    assert {:ok, nil} = ReactionCustody.claim_next("delivery:reaction:too-early", 60)

    Repo.update_all(Reaction, set: [next_attempt_at: @now])

    assert {:ok, retry} = ReactionCustody.claim_next("delivery:reaction:retry", 60)
    assert retry.reaction.id == first.reaction.id
    assert retry.reaction.attempt_count == 2
    refute retry.lease_ref == first.lease_ref
  end

  test "the current reaction owner can renew its opaque lease without spending an attempt" do
    entry = record_input!("Ev-reaction-renew")

    assert {:ok, _applied} =
             Admission.commit(context!(entry), reaction!("heart"), "decision:renew")

    assert {:ok, claim} = ReactionCustody.claim_next("delivery:reaction:renew", 1)

    assert {:ok, renewed} =
             ReactionCustody.renew(claim.reaction.delivery_ref, claim.lease_ref, 60)

    assert renewed.attempt_count == claim.reaction.attempt_count
    assert DateTime.compare(renewed.lease_expires_at, claim.reaction.lease_expires_at) == :gt

    assert {:error, :delivery_reaction_lease_lost} =
             ReactionCustody.renew(claim.reaction.delivery_ref, "wrong-lease", 60)
  end

  test "ignore creates no delivery outbox row" do
    entry = record_input!("Ev-ignore-custody")

    assert {:ok, ignored} =
             Admission.commit(context!(entry), ignore!(), "decision:ignore-custody")

    assert ignored.entry.status == :decided
    assert :error = ReactionCustody.fetch_by_input(entry.id)
    assert Repo.aggregate(Reaction, :count) == 0
  end

  test "invalid custody references are rejected before touching the queue" do
    assert :error = ReactionCustody.fetch_by_input("not-a-uuid")

    assert {:error, {:invalid_delivery_reaction, :worker_ref}} =
             ReactionCustody.claim_next("", 60)

    assert {:error, {:invalid_delivery_reaction, :request}} = ReactionCustody.request(:invalid)
  end

  test "the database requires an emoji name in every durable reaction document" do
    entry = record_input!("Ev-reaction-document-constraint")

    assert {:ok, _applied} =
             Admission.commit(context!(entry), reaction!("eyes"), "decision:document-constraint")

    assert {:ok, reaction} = ReactionCustody.fetch_by_input(entry.id)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE delivery_reactions SET document = '{}' WHERE id = $1", [
          Ecto.UUID.dump!(reaction.id)
        ])
      end

    assert error.postgres.constraint == "delivery_reaction_document_valid"
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
               workspace_ref: "T123"
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
               "reason" => "Acknowledge the source item without starting work.",
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
               "reason" => "No response is needed.",
               "work_class" => nil
             })

    decision
  end
end
