defmodule Responder.Ingress.InboxTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.ControlPlane.Projection
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.WorkProfile
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Slack.SourceRef

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
    assert entry.source_kind == "slack"
    assert entry.source_capabilities == %{"react" => %{"emoji_names" => nil}}

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

  test "a batch records every normalized input atomically" do
    stored = input!(event_ref: "Ev-batch-conflict", content: %{"text" => "original"})
    assert {:ok, _receipt} = Inbox.record(stored)

    new_input = input!(event_ref: "Ev-batch-new")
    conflict = input!(event_ref: "Ev-batch-conflict", content: %{"text" => "changed"})

    assert {:error, {:input_conflict, _details}} = Inbox.record_many([new_input, conflict])
    assert Repo.aggregate(Entry, :count) == 1

    assert {:ok, receipts} = Inbox.record_many([new_input, stored])
    assert Enum.map(receipts, & &1.status) == [:recorded, :duplicate]
    assert Repo.aggregate(Entry, :count) == 2
  end

  test "freezes execution mode on first receipt instead of re-reading channel settings" do
    input = input!(event_ref: "Ev-shadow")

    assert {:ok, %{status: :recorded, entry: first}} =
             Inbox.record(input, execution_mode: :shadow)

    assert first.execution_mode == :shadow

    assert {:ok, %{status: :duplicate, entry: retried}} =
             Inbox.record(input, execution_mode: :live)

    assert retried.id == first.id
    assert retried.execution_mode == :shadow
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "freezes trusted work placement on first receipt instead of accepting retry drift" do
    input = input!(event_ref: "Ev-work-placement")

    original = %{
      authority_digest: String.duplicate("8", 64),
      class_policies: %{
        conversational: %{
          authority_digest: String.duplicate("8", 64),
          policy: "incident-conversation-v1",
          policy_digest: String.duplicate("b", 64)
        },
        standard: %{
          authority_digest: String.duplicate("8", 64),
          policy: "incident-standard-v1",
          policy_digest: String.duplicate("c", 64)
        },
        deep: %{
          authority_digest: String.duplicate("8", 64),
          policy: "incident-deep-v1",
          policy_digest: String.duplicate("d", 64)
        }
      },
      policy: "incident-read-v1",
      policy_digest: String.duplicate("a", 64),
      repository_ref: "infrastructure"
    }

    changed = %{
      authority_digest: String.duplicate("9", 64),
      class_policies: %{
        conversational: %{
          authority_digest: String.duplicate("9", 64),
          policy: "changed-conversation-v2",
          policy_digest: String.duplicate("f", 64)
        },
        standard: %{
          authority_digest: String.duplicate("9", 64),
          policy: "changed-standard-v2",
          policy_digest: String.duplicate("0", 64)
        },
        deep: %{
          authority_digest: String.duplicate("9", 64),
          policy: "changed-deep-v2",
          policy_digest: String.duplicate("1", 64)
        }
      },
      policy: "incident-read-v2",
      policy_digest: String.duplicate("e", 64),
      repository_ref: "backend"
    }

    assert {:ok, %{status: :recorded, entry: first}} =
             Inbox.record(input, work_profile: original)

    assert first.work_policy == original.policy
    assert first.work_policy_digest == original.policy_digest
    assert first.repository_ref == original.repository_ref
    assert {:ok, frozen_profile} = WorkProfile.prepare(original)
    assert first.work_profile == WorkProfile.document(frozen_profile)

    assert {:ok, %{status: :duplicate, entry: retried}} =
             Inbox.record(input, work_profile: changed)

    assert retried.work_policy == original.policy
    assert retried.work_policy_digest == original.policy_digest
    assert retried.repository_ref == original.repository_ref
    assert retried.work_profile == WorkProfile.document(frozen_profile)
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "the database rejects a malformed frozen work class profile" do
    profile = %{
      authority_digest: String.duplicate("e", 64),
      class_policies: %{
        conversational: %{
          authority_digest: String.duplicate("e", 64),
          policy: "conversation-v1",
          policy_digest: String.duplicate("b", 64)
        },
        standard: %{
          authority_digest: String.duplicate("e", 64),
          policy: "standard-v1",
          policy_digest: String.duplicate("c", 64)
        },
        deep: %{
          authority_digest: String.duplicate("e", 64),
          policy: "deep-v1",
          policy_digest: String.duplicate("d", 64)
        }
      },
      policy: "base-v1",
      policy_digest: String.duplicate("a", 64),
      repository_ref: "infrastructure"
    }

    assert {:ok, %{entry: entry}} =
             Inbox.record(input!(event_ref: "Ev-work-profile-constraint"), work_profile: profile)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          UPDATE ingress_inbox_entries
          SET work_profile = jsonb_set(
            work_profile::jsonb,
            '{class_policies,deep,policy_digest}',
            '\"wrong\"'::jsonb
          )::text
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(entry.id)]
        )
      end

    assert error.postgres.constraint == "ingress_inbox_work_class_profile_valid"
  end

  test "the database rejects mismatched model-class execution authority" do
    authority_digest = String.duplicate("e", 64)

    profile = %{
      authority_digest: authority_digest,
      class_policies: %{
        conversational: %{
          authority_digest: authority_digest,
          policy: "conversation-v1",
          policy_digest: String.duplicate("b", 64)
        },
        standard: %{
          authority_digest: authority_digest,
          policy: "standard-v1",
          policy_digest: String.duplicate("c", 64)
        },
        deep: %{
          authority_digest: authority_digest,
          policy: "deep-v1",
          policy_digest: String.duplicate("d", 64)
        }
      },
      policy: "base-v1",
      policy_digest: String.duplicate("a", 64),
      repository_ref: "infrastructure"
    }

    assert {:ok, %{entry: entry}} =
             Inbox.record(input!(event_ref: "Ev-work-authority-constraint"),
               work_profile: profile
             )

    authority_error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          UPDATE ingress_inbox_entries
          SET work_profile = jsonb_set(
            work_profile::jsonb,
            '{class_policies,deep,authority_digest}',
            to_jsonb($2::text)
          )::text
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(entry.id), String.duplicate("f", 64)]
        )
      end

    assert authority_error.postgres.constraint == "ingress_inbox_work_class_profile_valid"
  end

  test "the database rejects a present null model-class authority" do
    authority_digest = String.duplicate("e", 64)

    profile = %{
      authority_digest: authority_digest,
      class_policies: %{
        conversational: %{
          authority_digest: authority_digest,
          policy: "conversation-v1",
          policy_digest: String.duplicate("b", 64)
        },
        standard: %{
          authority_digest: authority_digest,
          policy: "standard-v1",
          policy_digest: String.duplicate("c", 64)
        },
        deep: %{
          authority_digest: authority_digest,
          policy: "deep-v1",
          policy_digest: String.duplicate("d", 64)
        }
      },
      policy: "base-v1",
      policy_digest: String.duplicate("a", 64),
      repository_ref: "infrastructure"
    }

    assert {:ok, %{entry: entry}} =
             Inbox.record(input!(event_ref: "Ev-work-null-authority-constraint"),
               work_profile: profile
             )

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          UPDATE ingress_inbox_entries
          SET work_profile = jsonb_set(
            work_profile::jsonb,
            '{class_policies,deep,authority_digest}',
            'null'::jsonb
          )::text
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(entry.id)]
        )
      end

    assert error.postgres.constraint == "ingress_inbox_work_class_profile_valid"
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

  test "unbounded receipt order continues beyond a provider's first thousand occurrences" do
    assert {:ok, %{entry: first}} =
             Inbox.record(input!(event_ref: "Ev-provider-1000", revision: 1_000))

    assert {:ok, %{entry: next}} =
             Inbox.record(
               input!(
                 content: %{"text" => "a later provider occurrence"},
                 event_ref: "Ev-provider-1001",
                 revision: 1
               ),
               revision_ties: :receipt_order_unbounded
             )

    assert first.native_input_id == next.native_input_id
    assert next.revision == 1_001
  end

  test "claims the oldest eligible input and fences retry updates with its lease" do
    assert {:ok, %{entry: first}} = Inbox.record(input!(event_ref: "Ev-first"))

    assert {:ok, %{entry: _second}} =
             Inbox.record(
               input!(
                 event_ref: "Ev-second",
                 channel_ref: "C789",
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

  # The Lab could wait behind unrelated minute-long classifiers. More slots are
  # safe only if later messages cannot classify against an unfinished earlier
  # message from the same conversation, including during retry backoff.
  test "a slow admission blocks only its conversation and preserves message order" do
    {:ok, %{entry: first}} = Inbox.record(input!(event_ref: "Ev-order-first"))

    {:ok, %{entry: second}} =
      Inbox.record(input!(event_ref: "Ev-order-second", message_ref: "1787832001.000100"))

    {:ok, %{entry: other}} =
      Inbox.record(input!(event_ref: "Ev-order-other", channel_ref: "C789"))

    {:ok, %{entry: claimed, lease_ref: lease}} = Inbox.claim_next("slot:1", @occurred_at, 60)
    assert claimed.id == first.id
    assert {:ok, %{entry: independent}} = Inbox.claim_next("slot:2", @occurred_at, 60)
    assert independent.id == other.id
    assert {:ok, nil} = Inbox.claim_next("slot:3", @occurred_at, 60)

    assert {:ok, _} =
             Inbox.defer(
               Inbox.ref(first),
               lease,
               @occurred_at,
               1_000,
               "retry",
               "Retry under the same request identity"
             )

    assert {:ok, nil} = Inbox.claim_next("slot:3", @occurred_at, 60)

    assert {:ok, %{entry: retry, lease_ref: next_lease}} =
             Inbox.claim_next("slot:3", DateTime.add(@occurred_at, 1, :second), 60)

    assert retry.id == first.id

    assert {:ok, _} =
             Inbox.block(Inbox.ref(first), next_lease, "blocked", "Operator recovery required")

    assert {:ok, %{entry: following}} =
             Inbox.claim_next("slot:4", DateTime.add(@occurred_at, 1, :second), 60)

    assert following.id == second.id
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

  test "an operator can rearm one exact blocked admission without changing its frozen decision context" do
    assert {:ok, %{entry: entry}} = Inbox.record(input!(event_ref: "Ev-operator-rearm"))

    assert {:ok, %{lease_ref: lease_ref}} =
             Inbox.claim_next("executor:operator-rearm", @occurred_at, 60)

    context = %{"candidate_episode_ids" => [], "input" => %{"event_ref" => entry.event_ref}}

    assert {:ok, frozen} = Inbox.bind_context(Inbox.ref(entry), lease_ref, context)

    assert {:ok, _blocked} =
             Inbox.block(
               Inbox.ref(entry),
               lease_ref,
               "operation_uncertain",
               "Coop could not prove the exact mutation outcome"
             )

    assert {:ok, %{action: :rearm, ref: blocked_ref, status: :blocked}} =
             Projection.admission(Inbox.ref(entry))

    assert blocked_ref == Inbox.ref(entry)

    assert {:ok, rearmed} = Inbox.rearm(Inbox.ref(entry))
    assert rearmed.status == :pending
    assert rearmed.attempt_count == 0
    assert rearmed.admission_context == frozen.admission_context
    assert rearmed.admission_context_fingerprint == frozen.admission_context_fingerprint
    assert rearmed.execution_generation == frozen.execution_generation
    assert rearmed.validation_generation == frozen.validation_generation
    assert rearmed.last_error_code == nil
    assert rearmed.lease_ref == nil

    assert {:error, {:ingress_rearm_failed, :input_not_blocked}} =
             Inbox.rearm(Inbox.ref(entry))
  end

  test "the database requires an exact source item before a reaction can be admitted" do
    assert {:ok, %{entry: entry}} = Inbox.record(input!(event_ref: "Ev-reaction-target"))

    assert_raise Postgrex.Error, ~r/ingress_inbox_source_capabilities_valid/, fn ->
      Repo.query!(
        "UPDATE ingress_inbox_entries SET source_item_ref = NULL WHERE id = $1",
        [Ecto.UUID.dump!(entry.id)]
      )
    end
  end

  test "the database cannot move a Slack post grant onto a non-user source" do
    destination_ref = SourceRef.channel("T123", "C789")

    assert {:ok, %{entry: entry}} =
             Inbox.record(
               input!(
                 actor: %{kind: :user, ref: "U123"},
                 event_ref: "Ev-post-grant",
                 post_destination_refs: [destination_ref]
               )
             )

    assert_raise Postgrex.Error, ~r/ingress_inbox_source_capabilities_valid/, fn ->
      Repo.query!(
        "UPDATE ingress_inbox_entries SET actor_kind = 'app' WHERE id = $1",
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
