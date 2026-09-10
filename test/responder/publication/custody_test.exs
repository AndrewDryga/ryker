defmodule Responder.Publication.CustodyTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Observability
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.Publication.Operator, as: PublicationOperator
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.State.Records

  alias Responder.Work.{
    Cancellation,
    Custody,
    DeliveryReceipt,
    Result,
    Submission,
    Turn,
    TurnChangeset
  }

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "follow-up work waits for its active readiness review without spending an attempt" do
    # Automatically starting checks must not race the next Slack reply against
    # Coop's single active operation and burn the task's retry budget.
    %{claim: claim, offer: offer, offer_receipt: receipt} = delivered_offer!("review-first")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(claim, offer, receipt))

    assert {:ok, review} = PublicationCustody.claim_next("publication:review-first", 60)
    followup = admit_followup!(claim)

    assert Custody.claim_next("work:followup", 60, :work) == {:ok, nil}
    refute Repo.exists?(from(t in Responder.Work.Turn, where: t.turn_ref == ^followup.turn_ref))

    # A concurrent Work claimant can materialize its pending turn before the
    # post-lock review check. That intentional wait must not fail readiness.
    pending =
      Repo.insert!(
        TurnChangeset.insert(
          Ecto.UUID.generate(),
          claim.episode.id,
          claim.session.id,
          followup.turn_ref
        )
      )

    old = DateTime.add(DateTime.utc_now(), -3_600, :second)
    Repo.update_all(from(t in Turn, where: t.id == ^pending.id), set: [inserted_at: old])
    assert {:ok, snapshot} = Observability.snapshot(900)
    assert Enum.find(snapshot.queues, &(&1.name == :work)).claimable == 0
    refute :work in snapshot.stalled_queues

    assert {:ok, _released} =
             PublicationCustody.defer(
               publication.ref,
               review.lease_ref,
               1,
               "review_retry",
               "Retry"
             )

    assert {:ok, work} = Custody.claim_next("work:followup", 60, :work)
    assert work.session.id == claim.session.id
    assert work.turn.turn_ref == followup.turn_ref
    assert work.turn.work_attempt_count == 1
  end

  test "readiness waits for admitted follow-up work and does not starve another session" do
    %{claim: claim, offer: offer, offer_receipt: receipt} = delivered_offer!("work-first")

    assert {:ok, %{publication: waiting}} =
             PublicationCustody.request_review(review_request(claim, offer, receipt))

    %{claim: other, offer: other_offer, offer_receipt: other_receipt} =
      delivered_offer!("independent-review")

    assert {:ok, %{publication: independent}} =
             PublicationCustody.request_review(review_request(other, other_offer, other_receipt))

    admit_followup!(claim)
    assert {:ok, review} = PublicationCustody.claim_next("publication:independent", 60)
    assert review.publication.id == independent.id
    assert Repo.get!(Publication, waiting.id).attempt_count == 0
    old = DateTime.add(DateTime.utc_now(), -3_600, :second)
    Repo.update_all(from(p in Publication, where: p.id == ^waiting.id), set: [updated_at: old])
    assert {:ok, snapshot} = Observability.snapshot(900)
    assert Enum.find(snapshot.queues, &(&1.name == :publication)).claimable == 0
    refute :publication in snapshot.stalled_queues
    assert {:ok, work} = Custody.claim_next("work:first", 60, :work)
    assert work.session.id == claim.session.id
    assert PublicationCustody.claim_next("publication:waiting", 60) == {:ok, nil}
    assert Repo.get!(Publication, waiting.id).attempt_count == 0
  end

  test "checks wait for recovery after a blocked follow-up closes their workspace" do
    # Block requires closed-session proof, not just a stopped turn. A status-only
    # exception would send RunReview into a closed Coop workspace.
    %{claim: claim, offer: offer, offer_receipt: receipt} = delivered_offer!("blocked-followup")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(claim, offer, receipt))

    admit_followup!(claim)
    assert {:ok, work} = Custody.claim_next("work:blocked-followup", 60, :work)

    assert {:ok, _} =
             Custody.request_block(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               work.lease_ref,
               "The follow-up cannot continue."
             )

    assert {:ok, cancellation} = Custody.claim_next("work:stop-followup", 60, :work)

    assert {:ok, stopped} =
             Cancellation.absent_receipt(
               "responder:work:create:#{work.session.id}:g#{work.session.create_generation}",
               nil,
               work.session.coop_session_id,
               "closed",
               "responder:work:cancel-close:#{work.turn.id}:g1"
             )

    assert {:ok, settled} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               cancellation.lease_ref,
               stopped
             )

    assert settled.turn.status == :blocked
    assert settled.episode.state == :working

    assert PublicationCustody.claim_next("review:after-block", 60) == {:ok, nil}
    assert Repo.get!(Publication, publication.id).attempt_count == 0
  end

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

  test "operator retry is fenced to the exact deferred publication generation" do
    %{claim: claim, offer: offer, offer_receipt: receipt} = delivered_offer!("recover-retry")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(claim, offer, receipt))

    assert {:ok, active} = PublicationCustody.claim_next("publication:recover-active", 60)

    assert PublicationCustody.recover(publication.ref, :retry, 1) ==
             {:error, :publication_recovery_lease_active}

    assert {:ok, deferred} =
             PublicationCustody.defer(
               publication.ref,
               active.lease_ref,
               300,
               "coop_unavailable",
               "Coop did not answer."
             )

    assert {:ok, %{previous: previous, publication: recovered}} =
             PublicationCustody.recover(publication.ref, :retry, 1)

    assert previous == %{
             "last_error_code" => "coop_unavailable",
             "recovery_generation" => 1,
             "status" => "review_pending"
           }

    assert recovered.status == :review_pending
    assert recovered.recovery_generation == 2
    assert recovered.last_error_code == nil
    assert recovered.last_error_detail == nil
    assert %DateTime{} = recovered.next_attempt_at
    assert DateTime.compare(recovered.next_attempt_at, deferred.next_attempt_at) == :lt

    assert PublicationCustody.recover(publication.ref, :retry, 1) ==
             {:error, :publication_recovery_generation_stale}
  end

  test "operator update safely replaces only an unapproved review outcome" do
    reviewed = reviewed_publication!("recover-update", true)

    assert {:ok, %{publication: updated}} =
             PublicationCustody.recover(reviewed.ref, :update, 1)

    assert updated.status == :review_pending
    assert updated.review_generation == reviewed.review_generation + 1
    assert updated.recovery_generation == 2
    assert updated.review_expected_revision == nil
    assert updated.review_document == nil
    assert updated.review_patch == nil
    assert updated.review_delivery_receipt == nil
  end

  test "a first-publish race persists exact PR identity before recovery" do
    reviewed = reviewed_publication!("recover-first-publish-race", true)

    assert {:ok, %{publication: approved, status: :approved}} =
             PublicationCustody.approve(%{
               actor_ref: "slack:user:U-operator",
               approval_ref: "interaction:first-publish-race",
               occurred_at: @now,
               publication_ref: reviewed.ref,
               target: %{
                 conversation_ref: reviewed.destination_conversation_ref,
                 message_ref: reviewed.review_delivery_receipt["message_ref"],
                 thread_ref: reviewed.destination_thread_ref,
                 transport: reviewed.destination_transport
               }
             })

    assert approved.status == :publish_pending
    assert {:ok, claim} = PublicationCustody.claim_next("publication:first-race", 60)
    observed = String.duplicate("8", 40)
    candidate = String.duplicate("9", 40)

    receipt = %{
      "branch_ref" => "refs/heads/responder/first-race",
      "candidate_commit_sha" => candidate,
      "github_repository" => "acme/responder",
      "observed_head_sha" => observed,
      "pull_request_number" => 42,
      "pull_request_url" => "https://github.com/acme/responder/pull/42",
      "repository" => "responder"
    }

    assert {:ok, conflicted} =
             PublicationCustody.store_conflict(
               approved.ref,
               claim.lease_ref,
               :publication_branch_already_exists,
               receipt
             )

    assert conflicted.expected_remote_head_sha == observed
    assert conflicted.commit_sha == candidate
    assert conflicted.pull_request_number == 42
    assert conflicted.last_error_code == "publication_branch_already_exists"

    Repo.update_all(
      from(saved in Publication, where: saved.id == ^approved.id),
      set: [lease_expires_at: @now, next_attempt_at: @now]
    )

    assert {:ok, nil} = PublicationCustody.claim_next("publication:must-not-retry", 60)

    assert PublicationCustody.recover(approved.ref, :retry, 1) ==
             {:error, :publication_recovery_not_allowed}

    assert {:ok, %{publication: updated}} =
             PublicationCustody.recover(approved.ref, :update, 1)

    assert updated.status == :review_pending
    assert updated.expected_remote_head_sha == observed
    assert updated.pull_request_number == 42
    assert updated.review_document == nil
    assert updated.approval_ref == nil
  end

  test "an unreconciled first-publish conflict remains discardable without update identity" do
    reviewed = reviewed_publication!("discard-unreconciled-first-publish", true)

    assert {:ok, %{publication: approved, status: :approved}} =
             PublicationCustody.approve(%{
               actor_ref: "slack:user:U-operator",
               approval_ref: "interaction:discard-unreconciled",
               occurred_at: @now,
               publication_ref: reviewed.ref,
               target: %{
                 conversation_ref: reviewed.destination_conversation_ref,
                 message_ref: reviewed.review_delivery_receipt["message_ref"],
                 thread_ref: reviewed.destination_thread_ref,
                 transport: reviewed.destination_transport
               }
             })

    assert {:ok, claim} = PublicationCustody.claim_next("publication:discard-unreconciled", 60)

    assert {:ok, conflicted} =
             PublicationCustody.defer(
               approved.ref,
               claim.lease_ref,
               60,
               "publication_pull_request_mismatch",
               "No exact App-owned pull request could be reconciled."
             )

    assert is_nil(conflicted.expected_remote_head_sha)

    assert {:ok, %{publication: discarded}} =
             PublicationCustody.recover(conflicted.ref, :discard, 1)

    assert discarded.status == :discarded
    assert discarded.recovery_generation == 2
    assert is_nil(discarded.expected_remote_head_sha)
  end

  test "operator discard preserves an unapproved review outcome as evidence" do
    blocked = reviewed_publication!("recover-discard", false)

    assert {:ok, %{publication: discarded}} =
             PublicationCustody.recover(blocked.ref, :discard, 1)

    assert discarded.status == :discarded
    assert discarded.recovery_generation == 2
    assert discarded.review_document == blocked.review_document
    assert discarded.review_delivery_receipt == blocked.review_delivery_receipt

    assert PublicationCustody.recover(discarded.ref, :retry, 2) ==
             {:error, :publication_recovery_not_allowed}
  end

  test "operator recovery audit is atomic, idempotent, and request-fingerprinted" do
    publication = reviewed_publication!("recover-audit", false)
    publication_ref = publication.ref

    options = [
      actor_ref: "control-plane:operator",
      action_ref: "operator-action:publication-discard"
    ]

    assert {:ok,
            %{
              actor_ref: "control-plane:operator",
              outcome: %{
                "publication_ref" => ^publication_ref,
                "recovery_generation" => 2,
                "status" => "discarded"
              },
              status: :recorded
            }} = PublicationOperator.recover(publication.ref, :discard, 1, options)

    assert {:ok, %{status: :duplicate}} =
             PublicationOperator.recover(publication.ref, :discard, 1, options)

    assert PublicationOperator.recover(publication.ref, :update, 1, options) ==
             {:error, :operator_action_conflict}
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

    assert PublicationCustody.recover("publication", :unknown, 1) ==
             {:error, {:invalid_publication, :recovery_action}}

    assert PublicationCustody.recover("publication", :retry, 0) ==
             {:error, {:invalid_publication, :recovery_generation}}

    assert PublicationOperator.recover("publication", :retry, 1, []) ==
             {:error, {:invalid_publication_recovery, :options}}

    assert PublicationOperator.recover(:publication, :retry, 1,
             actor_ref: "operator",
             action_ref: "operator-action:retry"
           ) == {:error, {:invalid_publication_recovery, :publication_ref}}
  end

  defp admit_followup!(claim) do
    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: claim.episode.destination_conversation_ref,
          thread_ref: claim.episode.destination_thread_ref,
          transport: claim.episode.destination_transport
        },
        episode_id: claim.episode.id,
        episode_key: claim.episode.key,
        native_input_id: "followup:#{claim.episode.id}",
        occurred_at: DateTime.utc_now(),
        payload: %{"text" => "Please include the follow-up correction."},
        turn_ref: "turn:followup:#{claim.episode.id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    command
  end

  defp reviewed_publication!(suffix, publishable?) do
    %{claim: claim, offer: offer, offer_receipt: receipt} = delivered_offer!(suffix)

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(claim, offer, receipt))

    assert {:ok, review_claim} = PublicationCustody.claim_next("publication:#{suffix}", 60)

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(
               publication.ref,
               review_claim.lease_ref,
               7
             )

    patch = if publishable?, do: "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n", else: nil

    review =
      claim
      |> review_document()
      |> Map.merge(%{
        "gate" => if(publishable?, do: "passed", else: "failed"),
        "not_publishable_reasons" => if(publishable?, do: [], else: ["gate_failed"]),
        "patch_artifact_id" => if(publishable?, do: "review-patch:#{suffix}", else: nil),
        "patch_bytes" => if(publishable?, do: byte_size(patch), else: 0),
        "patch_digest" => if(publishable?, do: digest(patch), else: nil),
        "publishable" => publishable?
      })

    assert {:ok, _ready} =
             PublicationCustody.store_review(
               publication.ref,
               review_claim.lease_ref,
               frozen.review_generation,
               review,
               patch
             )

    assert {:ok, delivery_claim} =
             PublicationCustody.claim_next("publication:#{suffix}:delivery", 60)

    assert {:ok, request} = PublicationCustody.delivery_request(delivery_claim.publication)

    assert {:ok, delivery_receipt} =
             DeliveryReceipt.new(
               request.ref,
               request.transport,
               request.conversation_ref,
               request.thread_ref,
               "message:#{suffix}:review"
             )

    assert {:ok, publication} =
             PublicationCustody.confirm_delivery(
               publication.ref,
               delivery_claim.lease_ref,
               delivery_receipt
             )

    publication
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
                   conversation_ref: "slack:TPUBLICATIONCUSTODY:C456",
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
