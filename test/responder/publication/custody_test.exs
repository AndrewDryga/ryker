defmodule Responder.Publication.CustodyTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.State.Records
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "a delivered inert offer becomes one reviewed and operator-approved publication" do
    %{claim: claim, offer: offer, offer_receipt: offer_receipt} = delivered_offer!("lifecycle")

    request = review_request(claim, offer, offer_receipt)

    assert {:ok, %{publication: publication, status: :requested}} =
             PublicationCustody.request_review(request)

    assert publication.repository == "responder"
    assert publication.session_id == claim.session.id

    assert {:ok, %{status: :duplicate, publication: duplicate}} =
             PublicationCustody.request_review(request)

    assert duplicate.id == publication.id

    assert {:ok, review_claim} = PublicationCustody.claim_next("publication:review", 60)
    assert review_claim.publication.id == publication.id
    assert review_claim.publication.attempt_count == 1

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(
               publication.ref,
               review_claim.lease_ref,
               7
             )

    review = review_document(claim)
    patch = "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"
    review = %{review | "patch_bytes" => byte_size(patch), "patch_digest" => digest(patch)}

    assert {:ok, reviewed} =
             PublicationCustody.store_review(
               publication.ref,
               review_claim.lease_ref,
               frozen.review_generation,
               review,
               patch
             )

    assert reviewed.status == :review_ready
    assert reviewed.review_patch == patch

    assert {:ok, review_delivery_claim} =
             PublicationCustody.claim_next("publication:review-delivery", 60)

    assert review_delivery_claim.publication.id == publication.id

    assert {:ok, review_delivery} =
             PublicationCustody.delivery_request(review_delivery_claim.publication)

    assert review_delivery.ref == "publication-review:#{publication.id}"

    assert review_delivery.document["records"] |> hd() |> Map.fetch!("kind") ==
             "publication_review"

    assert {:ok, review_receipt} =
             DeliveryReceipt.new(
               review_delivery.ref,
               "slack",
               claim.episode.destination_conversation_ref,
               claim.episode.destination_thread_ref,
               "message:reviewed"
             )

    assert {:ok, ready} =
             PublicationCustody.confirm_delivery(
               publication.ref,
               review_delivery_claim.lease_ref,
               review_receipt
             )

    assert ready.status == :reviewed

    approval = %{
      actor_ref: "slack:user:U-operator",
      approval_ref: "interaction:publish",
      occurred_at: DateTime.add(@now, 2, :second),
      publication_ref: publication.ref,
      target: %{
        conversation_ref: claim.episode.destination_conversation_ref,
        message_ref: "message:reviewed",
        thread_ref: claim.episode.destination_thread_ref,
        transport: "slack"
      }
    }

    crossed_approval = put_in(approval, [:target, :message_ref], "message:someone-else")

    assert PublicationCustody.approve(crossed_approval) ==
             {:error, :publication_review_delivery_mismatch}

    assert {:ok, %{status: :approved, publication: approved}} =
             PublicationCustody.approve(approval)

    assert approved.status == :publish_pending

    assert {:ok, %{status: :duplicate}} = PublicationCustody.approve(approval)

    assert {:ok, publish_claim} = PublicationCustody.claim_next("publication:publish", 60)
    assert publish_claim.publication.id == publication.id

    publication_receipt = %{
      "branch_ref" => "refs/heads/responder/#{publication.id}",
      "candidate_tree" => review["candidate_tree"],
      "commit_sha" => String.duplicate("9", 40),
      "pull_request_number" => 91,
      "pull_request_url" => "https://github.com/acme/responder/pull/91",
      "repository" => "responder"
    }

    assert {:ok, published_ready} =
             PublicationCustody.store_publication(
               publication.ref,
               publish_claim.lease_ref,
               publication_receipt
             )

    assert published_ready.status == :published_ready

    assert {:ok, published_delivery_claim} =
             PublicationCustody.claim_next("publication:result-delivery", 60)

    assert published_delivery_claim.publication.id == publication.id

    assert {:ok, published_delivery} =
             PublicationCustody.delivery_request(published_delivery_claim.publication)

    assert published_delivery.document["message"] =~ "pull/91"

    assert {:ok, published_receipt} =
             DeliveryReceipt.new(
               published_delivery.ref,
               "slack",
               claim.episode.destination_conversation_ref,
               claim.episode.destination_thread_ref,
               "message:published"
             )

    assert {:ok, published} =
             PublicationCustody.confirm_delivery(
               publication.ref,
               published_delivery_claim.lease_ref,
               published_receipt
             )

    assert published.status == :published
    assert published.publication_receipt == publication_receipt
  end

  test "crossed delivery controls and unpublishable review fail closed" do
    %{claim: claim, offer: offer, offer_receipt: offer_receipt} = delivered_offer!("closed")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(claim, offer, offer_receipt))

    assert {:ok, review_claim} = PublicationCustody.claim_next("publication:closed", 60)

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(
               publication.ref,
               review_claim.lease_ref,
               3
             )

    review =
      claim
      |> review_document()
      |> Map.merge(%{
        "gate" => "failed",
        "not_publishable_reasons" => ["gate_failed"],
        "patch_artifact_id" => nil,
        "patch_bytes" => 0,
        "patch_digest" => nil,
        "publishable" => false,
        "session_revision" => 3
      })

    assert {:ok, _ready} =
             PublicationCustody.store_review(
               publication.ref,
               review_claim.lease_ref,
               frozen.review_generation,
               review,
               nil
             )

    assert {:ok, delivery_claim} =
             PublicationCustody.claim_next("publication:closed-delivery", 60)

    assert delivery_claim.publication.id == publication.id
    assert {:ok, request} = PublicationCustody.delivery_request(delivery_claim.publication)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               request.ref,
               "slack",
               claim.episode.destination_conversation_ref,
               claim.episode.destination_thread_ref,
               "message:not-publishable"
             )

    assert {:ok, blocked} =
             PublicationCustody.confirm_delivery(
               publication.ref,
               delivery_claim.lease_ref,
               receipt
             )

    assert blocked.status == :blocked

    crossed = %{
      actor_ref: "slack:user:U-operator",
      approval_ref: "interaction:crossed",
      occurred_at: DateTime.add(@now, 3, :second),
      publication_ref: publication.ref,
      target: %{
        conversation_ref: claim.episode.destination_conversation_ref,
        message_ref: "message:someone-else",
        thread_ref: claim.episode.destination_thread_ref,
        transport: "slack"
      }
    }

    assert PublicationCustody.approve(crossed) == {:error, :publication_not_reviewed}
  end

  test "review mutations reconcile exact generations, revisions, leases, policy, and patch bytes" do
    %{claim: claim, offer: offer, offer_receipt: receipt} = delivered_offer!("review-fences")
    request = review_request(claim, offer, receipt)

    assert {:ok, %{publication: publication}} = PublicationCustody.request_review(request)

    assert PublicationCustody.request_review(%{request | request_ref: "other-request"}) ==
             {:error, :publication_offer_already_requested}

    assert {:ok, review_claim} = PublicationCustody.claim_next("publication:fences", 60)
    assert {:ok, renewed} = PublicationCustody.renew(publication.ref, review_claim.lease_ref, 120)
    assert renewed.lease_ref == review_claim.lease_ref

    assert {:ok, deferred} =
             PublicationCustody.defer(
               publication.ref,
               review_claim.lease_ref,
               1,
               "coop_unavailable",
               "The review session is temporarily unavailable."
             )

    refute deferred.lease_ref

    Repo.update_all(
      from(saved in Publication, where: saved.id == ^publication.id),
      set: [next_attempt_at: @now]
    )

    assert {:ok, review_claim} = PublicationCustody.claim_next("publication:fences:retry", 60)

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(
               publication.ref,
               review_claim.lease_ref,
               7
             )

    assert {:ok, same} =
             PublicationCustody.freeze_review_revision(
               publication.ref,
               review_claim.lease_ref,
               7
             )

    assert same.id == frozen.id

    assert PublicationCustody.freeze_review_revision(
             publication.ref,
             review_claim.lease_ref,
             8
           ) == {:error, :publication_review_revision_conflict}

    assert PublicationCustody.advance_review_generation(
             publication.ref,
             review_claim.lease_ref,
             frozen.review_generation + 1
           ) == {:error, :publication_review_generation_stale}

    assert {:ok, advanced} =
             PublicationCustody.advance_review_generation(
               publication.ref,
               review_claim.lease_ref,
               frozen.review_generation
             )

    assert advanced.review_generation == 2
    assert advanced.review_expected_revision == nil

    assert {:ok, refrozen} =
             PublicationCustody.freeze_review_revision(
               publication.ref,
               review_claim.lease_ref,
               7
             )

    review = review_document(claim)
    patch = "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"
    review = %{review | "patch_bytes" => byte_size(patch), "patch_digest" => digest(patch)}

    assert PublicationCustody.store_review(
             publication.ref,
             review_claim.lease_ref,
             refrozen.review_generation + 1,
             review,
             patch
           ) == {:error, :publication_review_generation_stale}

    assert PublicationCustody.store_review(
             publication.ref,
             review_claim.lease_ref,
             refrozen.review_generation,
             %{review | "policy_digest" => String.duplicate("b", 64)},
             patch
           ) == {:error, :publication_review_policy_mismatch}

    assert PublicationCustody.store_review(
             publication.ref,
             review_claim.lease_ref,
             refrozen.review_generation,
             review,
             "wrong patch"
           ) == {:error, :publication_review_patch_mismatch}

    assert {:ok, ready} =
             PublicationCustody.store_review(
               publication.ref,
               review_claim.lease_ref,
               refrozen.review_generation,
               review,
               patch
             )

    assert ready.status == :review_ready
  end

  test "publication custody public boundaries fail closed before queue mutation" do
    assert PublicationCustody.request_review(%{}) ==
             {:error, {:invalid_publication_review, :fields}}

    assert PublicationCustody.request_review(actor_ref: "a", actor_ref: "b") ==
             {:error, {:invalid_publication_review, :fields}}

    assert PublicationCustody.approve(%{}) ==
             {:error, {:invalid_publication_approval, :fields}}

    valid_review = %{
      actor_ref: "actor",
      occurred_at: @now,
      record_ref: "record",
      request_ref: "request",
      target: %{
        conversation_ref: "conversation",
        message_ref: "message",
        thread_ref: nil,
        transport: "slack"
      }
    }

    assert PublicationCustody.request_review(%{valid_review | occurred_at: "now"}) ==
             {:error, {:invalid_publication, :occurred_at}}

    assert PublicationCustody.request_review(%{valid_review | target: :invalid}) ==
             {:error, {:invalid_publication_target, :fields}}

    assert PublicationCustody.request_review(put_in(valid_review, [:target, :thread_ref], "")) ==
             {:error, {:invalid_publication, :thread_ref}}

    assert PublicationCustody.request_review(valid_review) ==
             {:error, :publication_offer_not_found}

    assert PublicationCustody.approve(%{
             actor_ref: "actor",
             approval_ref: "approval",
             occurred_at: @now,
             publication_ref: "publication:missing",
             target: valid_review.target
           }) == {:error, :publication_not_found}

    assert PublicationCustody.claim_next("", 0) ==
             {:error, {:invalid_publication, :worker_ref}}

    assert PublicationCustody.freeze_review_revision("publication", "lease", 0) ==
             {:error, {:invalid_publication, :review_expected_revision}}

    assert PublicationCustody.advance_review_generation("publication", "lease", 0) ==
             {:error, {:invalid_publication, :review_generation}}

    assert PublicationCustody.store_review("publication", "lease", 0, %{}, nil) ==
             {:error, {:invalid_publication, :review_generation}}

    assert PublicationCustody.renew("publication", "lease", 0) ==
             {:error, {:invalid_publication, :lease_seconds}}

    assert PublicationCustody.defer("publication", "lease", 0, "", "") ==
             {:error, {:invalid_publication, :retry_seconds}}

    assert PublicationCustody.store_publication("publication:missing", "lease", %{}) ==
             {:error, :publication_not_found}

    assert PublicationCustody.confirm_delivery("publication:missing", "lease", %{}) ==
             {:error, {:invalid_work_delivery_receipt, :fields}}

    assert PublicationCustody.delivery_request(%{}) ==
             {:error, :publication_delivery_not_pending}
  end

  defp delivered_offer!(suffix) do
    claim = claim_episode!(suffix)

    assert {:ok, _goal} =
             Records.create(Records.token(claim.turn), "goal-#{suffix}", "goal", %{
               "authority" => "repository_write",
               "completion_contract" => "The implementation is committed and reviewed.",
               "id" => "engineering-#{suffix}",
               "kind" => "engineering",
               "requested_outcome" => "Implement #{suffix}",
               "required" => true,
               "writable_repository" => "responder"
             })

    assert {:ok, offer} =
             Records.create(
               Records.token(claim.turn),
               "publication-#{suffix}",
               "publication_offer",
               %{
                 "body" => "Implements #{suffix} with focused regression coverage.",
                 "title" => "Implement #{suffix}"
               }
             )

    final = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The committed change is ready for review.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [offer.ref],
        "state" => "complete"
      }
    }

    candidate = Jason.encode!(final)
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

    assert {:ok, result} = Result.new(:reply, final)

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

    assert {:ok, delivery} = Custody.claim_next("delivery:#{suffix}", 60, :delivery)

    assert {:ok, offer_receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               claim.episode.destination_conversation_ref,
               claim.episode.destination_thread_ref,
               "message:offer:#{suffix}"
             )

    assert {:ok, _settled} =
             Custody.confirm_delivery(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               delivery.lease_ref,
               offer_receipt
             )

    %{claim: claim, offer: offer, offer_receipt: offer_receipt}
  end

  defp claim_episode!(suffix) do
    id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "thread:#{suffix}",
                   transport: "slack"
                 },
                 episode_id: id,
                 episode_key: "publication:#{suffix}:#{id}",
                 native_input_id: "source:#{suffix}:#{id}",
                 occurred_at: @now,
                 payload: %{"text" => "Implement #{suffix}."},
                 turn_ref: "turn:#{suffix}:#{id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(id, "work-contributor", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    bind_remote!(claim)
  end

  defp bind_remote!(claim) do
    assert {:ok, submission} =
             Submission.new(
               %{"input" => claim.episode.key},
               "Implement the frozen request.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, frozen} =
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

  defp review_request(claim, offer, receipt) do
    %{
      actor_ref: "slack:user:U-operator",
      occurred_at: DateTime.add(@now, 1, :second),
      record_ref: offer.ref,
      request_ref: "interaction:review:#{offer.id}",
      target: %{
        conversation_ref: claim.episode.destination_conversation_ref,
        message_ref: receipt["message_ref"],
        thread_ref: claim.episode.destination_thread_ref,
        transport: "slack"
      }
    }
  end

  defp review_document(claim) do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "op-review-#{claim.episode.id}",
      "parent_head" => String.duplicate("4", 40),
      "parent_tree" => String.duplicate("5", 40),
      "patch_artifact_id" => "op-review-#{claim.episode.id}",
      "patch_bytes" => 1,
      "patch_digest" => String.duplicate("8", 64),
      "patch_truncated" => false,
      "policy_digest" => String.duplicate("a", 64),
      "policy_findings" => [],
      "publishable" => true,
      "rebase" => "clean",
      "session_id" => claim.session.coop_session_id,
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
