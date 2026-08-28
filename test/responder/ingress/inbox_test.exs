defmodule Responder.Ingress.InboxTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Slack.Input, as: SlackInput

  @occurred_at ~U[2026-08-27 12:00:00Z]

  test "records an arbitrary Slack event without interpreting its provider" do
    content = %{
      "blocks" => [%{"type" => "rich_text", "vendor_state" => "something-new"}],
      "files" => [%{"id" => "F1", "mimetype" => "application/octet-stream"}],
      "text" => "A message from an app added tomorrow"
    }

    input = input!(content: content)

    assert {:ok, %{status: :recorded, entry: entry}} = Inbox.record(input)
    assert entry.content == content
    assert entry.status == :pending
    assert entry.episode_id == nil
    assert entry.occurred_at == ~U[2026-08-27 12:00:00.000000Z]
    assert entry.source_item_ref == "1787832000.000100"

    assert {:ok, loaded} = Inbox.fetch(Inbox.ref(entry))
    assert loaded.id == entry.id
    assert loaded.content == content
    assert loaded.source_item_ref == "1787832000.000100"
  end

  test "returns the original durable record when Slack retries the exact event" do
    input = input!()

    assert {:ok, %{status: :recorded, entry: first}} = Inbox.record(input)
    assert {:ok, %{status: :duplicate, entry: retried}} = Inbox.record(input)

    assert retried.id == first.id
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "rejects a reused Slack event identity with changed content" do
    assert {:ok, %{entry: stored}} = Inbox.record(input!())

    assert {:error,
            {:input_conflict,
             dedupe_key: dedupe_key,
             stored_fingerprint: stored_fingerprint,
             submitted_fingerprint: submitted_fingerprint}} =
             Inbox.record(input!(content: %{"text" => "different bytes"}))

    assert dedupe_key == stored.dedupe_key
    assert stored_fingerprint == stored.event_fingerprint
    refute submitted_fingerprint == stored_fingerprint
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "keeps different Slack events independent even when they update one message" do
    assert {:ok, %{entry: first}} = Inbox.record(input!())

    assert {:ok, %{entry: edit}} =
             Inbox.record(
               input!(
                 event_kind: :edit,
                 event_ref: "Ev-edit",
                 revision: 2,
                 content: %{"text" => "edited"}
               )
             )

    refute first.id == edit.id

    assert Repo.all(from(entry in Entry, order_by: entry.revision, select: entry.revision)) ==
             [1, 2]
  end

  test "claims the oldest eligible input and fences retry updates with its lease" do
    assert {:ok, %{entry: first}} = Inbox.record(input!(event_ref: "Ev-first"))

    assert {:ok, %{entry: _second}} =
             Inbox.record(
               input!(
                 event_ref: "Ev-second",
                 message_ref: "1787832001.000100",
                 occurred_at: DateTime.add(@occurred_at, 1, :second)
               )
             )

    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("executor:test", @occurred_at, 60)

    assert claimed.id == first.id
    assert claimed.attempt_count == 1
    assert claimed.lease_owner == "executor:test"
    assert claimed.lease_ref == lease_ref

    assert DateTime.compare(claimed.lease_expires_at, DateTime.add(@occurred_at, 60, :second)) ==
             :eq

    assert {:error, {:ingress_retry_failed, :lease_lost}} =
             Inbox.defer(
               Inbox.ref(claimed),
               "ingress-lease:wrong",
               @occurred_at,
               1_000,
               "coop_unavailable",
               "temporary failure"
             )

    assert {:ok, deferred} =
             Inbox.defer(
               Inbox.ref(claimed),
               lease_ref,
               @occurred_at,
               1_000,
               "coop_unavailable",
               "temporary failure"
             )

    assert deferred.lease_ref == nil

    assert DateTime.compare(deferred.next_attempt_at, DateTime.add(@occurred_at, 1, :second)) ==
             :eq

    assert deferred.last_error_code == "coop_unavailable"

    assert {:ok, %{entry: next}} =
             Inbox.claim_next("executor:test", @occurred_at, 60)

    refute next.id == first.id
  end

  test "source occurrence time cannot jump ahead of earlier received work" do
    assert {:ok, %{entry: received_first}} =
             Inbox.record(input!(event_ref: "Ev-received-first"))

    assert {:ok, %{entry: backfilled_later}} =
             Inbox.record(
               input!(
                 event_ref: "Ev-backfilled-later",
                 message_ref: "1787832001.000100",
                 occurred_at: ~U[2020-01-01 00:00:00Z]
               )
             )

    assert DateTime.compare(received_first.inserted_at, backfilled_later.inserted_at) in [
             :lt,
             :eq
           ]

    assert {:ok, %{entry: claimed}} =
             Inbox.claim_next("executor:receipt-order", @occurred_at, 60)

    assert claimed.id == received_first.id
  end

  test "an expired claim becomes eligible without spending or losing the input" do
    assert {:ok, %{entry: entry}} = Inbox.record(input!(event_ref: "Ev-expired"))
    assert {:ok, %{lease_ref: first_lease}} = Inbox.claim_next("executor:old", @occurred_at, 1)

    assert {:ok, nil} = Inbox.claim_next("executor:new", @occurred_at, 60)

    later = DateTime.add(@occurred_at, 2, :second)

    assert {:ok, %{entry: reclaimed, lease_ref: second_lease}} =
             Inbox.claim_next("executor:new", later, 60)

    assert reclaimed.id == entry.id
    assert reclaimed.attempt_count == 2
    refute second_lease == first_lease

    assert {:error, {:ingress_retry_failed, :lease_lost}} =
             Inbox.defer(
               Inbox.ref(entry),
               first_lease,
               later,
               1_000,
               "late_worker",
               "stale executor finished after its lease expired"
             )
  end

  test "the current executor can renew its fenced lease without spending another attempt" do
    assert {:ok, %{entry: entry}} = Inbox.record(input!(event_ref: "Ev-renewed-lease"))
    assert {:ok, %{lease_ref: lease_ref}} = Inbox.claim_next("executor:slow", @occurred_at, 2)

    renewed_at = DateTime.add(@occurred_at, 1, :second)

    assert {:ok, renewed} =
             Inbox.renew(Inbox.ref(entry), lease_ref, renewed_at, 2)

    assert renewed.attempt_count == 1
    assert renewed.lease_ref == lease_ref

    assert DateTime.compare(
             renewed.lease_expires_at,
             DateTime.add(@occurred_at, 3, :second)
           ) == :eq

    assert {:ok, nil} =
             Inbox.claim_next("executor:other", DateTime.add(@occurred_at, 2, :second), 2)

    assert {:ok, %{entry: reclaimed}} =
             Inbox.claim_next("executor:other", DateTime.add(@occurred_at, 4, :second), 2)

    assert reclaimed.id == entry.id
    assert reclaimed.attempt_count == 2
  end

  test "irreducibly uncertain work leaves the retry queue under durable custody" do
    assert {:ok, %{entry: entry}} = Inbox.record(input!(event_ref: "Ev-uncertain"))

    assert {:ok, %{lease_ref: lease_ref}} =
             Inbox.claim_next("executor:test", @occurred_at, 60)

    assert {:ok, blocked} =
             Inbox.block(
               Inbox.ref(entry),
               lease_ref,
               "operation_uncertain",
               "Coop cannot prove whether validation was accepted"
             )

    assert blocked.status == :blocked
    assert blocked.lease_ref == nil
    assert blocked.next_attempt_at == nil
    assert blocked.last_error_code == "operation_uncertain"

    assert {:ok, nil} =
             Inbox.claim_next("executor:test", DateTime.add(@occurred_at, 1, :hour), 60)
  end

  test "the database requires an exact source item before a reaction can be admitted" do
    assert {:ok, %{entry: entry}} = Inbox.record(input!(event_ref: "Ev-reaction-target"))

    assert_raise Postgrex.Error, ~r/ingress_inbox_reaction_target_valid/, fn ->
      Repo.query!(
        "UPDATE ingress_inbox_entries SET source_item_ref = NULL WHERE id = $1",
        [Ecto.UUID.dump!(entry.id)]
      )
    end
  end

  defp input!(overrides \\ []) do
    attributes =
      Keyword.merge(
        [
          actor: %{kind: :app, ref: "A123"},
          channel_ref: "C456",
          content: %{"text" => "A generic Slack message"},
          event_kind: :message,
          event_ref: "Ev123",
          message_ref: "1787832000.000100",
          occurred_at: @occurred_at,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "T123"
        ],
        overrides
      )

    assert {:ok, input} = SlackInput.new(attributes)
    input
  end
end
