defmodule Responder.State.MemoriesTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.State.{Memories, MemoryEntry, Record, Records}
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "confirmed operational memory is scoped, provenance-bearing, replaceable, and forgettable" do
    fixture = delivered_offers!("lifecycle")

    assert {:ok, first} =
             Memories.confirm(confirmation(fixture, fixture.first, "first"))

    assert first.status == :confirmed
    assert first.memory.kind == :repository_binding
    assert first.memory.scope_kind == :conversation
    assert first.memory.scope_ref == "slack:T123:C456"
    assert first.memory.payload["value"] == "responder"

    context = %{
      conversation_ref: "slack:T123:C456",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert [recalled] = Memories.recall(context)
    assert recalled["memory_ref"] == first.memory.ref
    assert recalled["value"] == "responder"
    assert recalled["source"]["message_ref"] == fixture.receipt["message_ref"]

    refute inspect(recalled) =~ "confirmation_ref"
    assert Memories.recall(%{context | conversation_ref: "slack:T123:C999"}) == []

    first_recalled = Repo.get!(MemoryEntry, first.memory.id)
    assert first_recalled.recall_count == 1
    assert %DateTime{} = first_recalled.last_recalled_at

    assert {:ok, replacement} =
             Memories.confirm(confirmation(fixture, fixture.replacement, "replacement"))

    assert replacement.memory.payload["value"] == "responder-next"

    superseded = Repo.get!(MemoryEntry, first.memory.id)
    assert superseded.status == :superseded
    assert superseded.payload == %{"replaced_payload_sha256" => first.memory.payload_fingerprint}
    refute inspect(superseded.payload) =~ "responder"
    assert Memories.forget(first.memory.ref) == {:error, :memory_terminal}

    assert [latest] = Memories.recall(context)
    assert latest["memory_ref"] == replacement.memory.ref
    assert latest["value"] == "responder-next"

    assert Memories.forget(replacement.memory.ref, "slack:T999") ==
             {:error, :memory_workspace_mismatch}

    assert Repo.get!(MemoryEntry, replacement.memory.id).status == :active

    assert {:ok, forgotten} = Memories.forget(replacement.memory.ref, "slack:T123")
    assert forgotten.status == :deleted
    assert forgotten.payload["forgotten_payload_sha256"] == replacement.memory.payload_fingerprint
    refute inspect(forgotten.payload) =~ "responder-next"
    assert Memories.recall(context) == []

    assert {:ok, duplicate_forget} = Memories.forget(replacement.memory.ref, "slack:T123")
    assert duplicate_forget.id == forgotten.id
  end

  test "explicit workspace visibility recalls across conversations while crossed controls fail closed" do
    fixture = delivered_offers!("visibility")

    assert {:ok, workspace} =
             Memories.confirm(confirmation(fixture, fixture.workspace, "workspace"))

    assert workspace.memory.visibility == :workspace

    assert [entry] =
             Memories.recall(%{
               conversation_ref: "slack:T123:C999",
               repository: nil,
               workspace_ref: "slack:T123"
             })

    assert entry["subject"] == "checkout_service"
    assert entry["value"] == "The checkout API is owned by Payments."

    crossed =
      fixture
      |> confirmation(fixture.first, "crossed")
      |> put_in([:target, :message_ref], "1787832999.999999")

    assert Memories.confirm(crossed) == {:error, :memory_offer_delivery_mismatch}

    Repo.update_all(
      from(record in Record, where: record.id == ^fixture.first.id),
      set: [status: :dismissed]
    )

    assert Memories.confirm(confirmation(fixture, fixture.first, "stale")) ==
             {:error, :memory_offer_stale}
  end

  test "memory listing, expiry, and forget controls never widen scope" do
    fixture = delivered_offers!("bounded")
    assert {:ok, confirmed} = Memories.confirm(confirmation(fixture, fixture.first, "bounded"))

    assert [listed] = Memories.list("slack:T123")
    assert listed.ref == confirmed.memory.ref
    assert [active] = Memories.list("slack:T123", status: :active)
    assert active.ref == confirmed.memory.ref
    assert Memories.list("", status: :active) == []
    assert Memories.list("slack:T123", status: :unknown) == []
    assert Memories.list("slack:T123", extra: true) == []
    assert Memories.list("slack:T123", :not_options) == []

    assert Memories.recall(:invalid, 20) == []
    assert Memories.recall(%{}, 20) == []
    assert Memories.recall(%{}, 0) == []
    assert Memories.model_context(%{}, nil) == []

    Repo.update_all(
      from(entry in MemoryEntry, where: entry.id == ^confirmed.memory.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    context = %{
      conversation_ref: "slack:T123:C456",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert Memories.recall(context) == []
    assert Repo.get!(MemoryEntry, confirmed.memory.id).status == :active
    assert {:ok, deleted} = Memories.forget(confirmed.memory.ref)
    assert deleted.status == :deleted
    assert Memories.forget("missing-memory") == {:error, :memory_not_found}
    assert {:error, _reason} = Memories.forget("")
  end

  test "malformed memory confirmations fail before durable state changes" do
    assert {:error, _reason} = Memories.confirm(%{})
    assert {:error, _reason} = Memories.confirm(actor_ref: "a", actor_ref: "b")

    invalid_target = %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:invalid",
      occurred_at: "not-a-time",
      record_ref: "record:missing",
      target: %{}
    }

    assert {:error, _reason} = Memories.confirm(invalid_target)
  end

  defp delivered_offers!(suffix) do
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "1787832000.000100",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "memory-offer:#{suffix}:#{episode_id}",
                 native_input_id: "slack-message:memory:#{suffix}:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "turn:memory:#{suffix}:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:memory:#{suffix}", 60, :work)

    assert {:ok, first} =
             Records.create(Records.token(claim.turn), "first", "memory_offer", %{
               "expires_in" => "90d",
               "kind" => "repository_binding",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "primary_repository",
               "value" => "responder",
               "visibility" => "conversation"
             })

    assert {:ok, replacement} =
             Records.create(Records.token(claim.turn), "replacement", "memory_offer", %{
               "expires_in" => "90d",
               "kind" => "repository_binding",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "primary_repository",
               "value" => "responder-next",
               "visibility" => "conversation"
             })

    assert {:ok, workspace} =
             Records.create(Records.token(claim.turn), "workspace", "memory_offer", %{
               "expires_in" => "30d",
               "kind" => "entity_relationship",
               "repository" => nil,
               "scope" => "workspace",
               "subject" => "checkout_service",
               "value" => "The checkout API is owned by Payments.",
               "visibility" => "workspace"
             })

    bind_and_deliver!(claim, transition.episode, suffix, [first, replacement, workspace])
    |> Map.merge(%{first: first, replacement: replacement, workspace: workspace})
  end

  defp bind_and_deliver!(claim, episode, suffix, records) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode.id},
               "Offer the exact memory mappings for confirmation.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:memory:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:memory:#{suffix}"
             )

    candidate =
      ~s({"delivery":"reply","message":"I can remember those mappings after confirmation."})

    sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode.id,
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
               "message" => "I can remember those mappings after confirmation.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => Enum.map(records, & &1.ref),
                 "state" => "complete"
               }
             })

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode.id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode.id,
               episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:memory:#{suffix}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:memory:#{suffix}", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               "slack:T123:C456",
               "1787832000.000100",
               "1787832001.000200"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               episode.id,
               episode.key,
               turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{episode: settled.episode, receipt: receipt}
  end

  defp confirmation(fixture, record, suffix) do
    %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{suffix}",
      occurred_at: @now,
      record_ref: record.ref,
      target: %{
        conversation_ref: fixture.receipt["conversation_ref"],
        message_ref: fixture.receipt["message_ref"],
        thread_ref: fixture.receipt["thread_ref"],
        transport: fixture.receipt["transport"]
      }
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
