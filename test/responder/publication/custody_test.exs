defmodule Responder.Publication.CustodyTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Observability
  alias Responder.Publication.Changeset, as: PublicationChangeset
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.Publication.{Followup, Publication, Review}
  alias Responder.Publication.Operator, as: PublicationOperator
  alias Responder.Repo
  alias Responder.State.Records

  alias Responder.Work.{
    Cancellation,
    Custody,
    DeliveryReceipt,
    Result,
    Session,
    SessionChangeset,
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
             PublicationCustody.request_review(review_request(offer, receipt))

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
             PublicationCustody.request_review(review_request(offer, receipt))

    %{offer: other_offer, offer_receipt: other_receipt} =
      delivered_offer!("independent-review")

    assert {:ok, %{publication: independent}} =
             PublicationCustody.request_review(review_request(other_offer, other_receipt))

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
             PublicationCustody.request_review(review_request(offer, receipt))

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

    request = review_request(offer, offer_receipt)

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

    assert review_delivery.ref == "publication-review:#{publication.id}:g1"

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

  test "a publication offer delivered to a joined input's origin thread can be reviewed from that thread" do
    # Found live 2026-09-11: routing delivered a correction card to the joined
    # root's thread and the Save press was refused as "no longer current"; a
    # human sees the same.
    %{claim: claim, offer: offer, offer_receipt: receipt} =
      delivered_offer!("routed", delivery_thread_ref: "thread:routed-origin")

    assert claim.episode.destination_thread_ref == "thread:routed"
    assert receipt["thread_ref"] == "thread:routed-origin"

    assert {:ok, %{publication: publication, status: :requested}} =
             PublicationCustody.request_review(review_request(offer, receipt))

    assert publication.offer_message_ref == receipt["message_ref"]
  end

  test "a review requested from a joined input's origin thread posts its review card there" do
    # Found live 2026-09-11: routing delivered a correction card to the joined
    # root's thread and the Save press was refused as "no longer current"; a
    # human sees the same.
    %{claim: claim, offer: offer, offer_receipt: receipt} =
      delivered_offer!("routed-card", delivery_thread_ref: "thread:routed-card-origin")

    assert claim.episode.destination_thread_ref == "thread:routed-card"

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(offer, receipt))

    assert publication.destination_thread_ref == "thread:routed-card-origin"

    assert {:ok, review_claim} = PublicationCustody.claim_next("publication:routed-card", 60)

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(
               publication.ref,
               review_claim.lease_ref,
               7
             )

    patch = "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"

    review =
      claim
      |> review_document()
      |> Map.merge(%{"patch_bytes" => byte_size(patch), "patch_digest" => digest(patch)})

    assert {:ok, _reviewed} =
             PublicationCustody.store_review(
               publication.ref,
               review_claim.lease_ref,
               frozen.review_generation,
               review,
               patch
             )

    assert {:ok, delivery_claim} =
             PublicationCustody.claim_next("publication:routed-card-delivery", 60)

    assert {:ok, review_delivery} =
             PublicationCustody.delivery_request(delivery_claim.publication)

    assert review_delivery.thread_ref == "thread:routed-card-origin"

    assert {:ok, review_receipt} =
             DeliveryReceipt.new(
               review_delivery.ref,
               "slack",
               claim.episode.destination_conversation_ref,
               "thread:routed-card-origin",
               "message:routed-reviewed"
             )

    assert {:ok, ready} =
             PublicationCustody.confirm_delivery(
               publication.ref,
               delivery_claim.lease_ref,
               review_receipt
             )

    assert ready.status == :reviewed

    # Approval is verified where the review card went, so the operator who
    # pressed Request review reads and approves in one thread.
    approval = %{
      actor_ref: "slack:user:U-operator",
      approval_ref: "interaction:routed-publish",
      occurred_at: DateTime.add(@now, 2, :second),
      publication_ref: publication.ref,
      target: %{
        conversation_ref: claim.episode.destination_conversation_ref,
        message_ref: "message:routed-reviewed",
        thread_ref: "thread:routed-card-origin",
        transport: "slack"
      }
    }

    assert {:ok, %{status: :approved}} = PublicationCustody.approve(approval)
  end

  test "a publication offer is not reviewable from a thread its card was never delivered to" do
    %{claim: claim, offer: offer, offer_receipt: receipt} =
      delivered_offer!("routed-elsewhere", delivery_thread_ref: "thread:routed-elsewhere-origin")

    elsewhere =
      put_in(
        review_request(offer, receipt),
        [:target, :thread_ref],
        claim.episode.destination_thread_ref
      )

    assert PublicationCustody.request_review(elsewhere) ==
             {:error, :publication_offer_delivery_mismatch}

    assert Repo.aggregate(Publication, :count, :id) == 0
  end

  test "crossed delivery controls and unpublishable review fail closed" do
    %{claim: claim, offer: offer, offer_receipt: offer_receipt} = delivered_offer!("closed")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(offer, offer_receipt))

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

    # A failed gate is not a shareable snapshot either, so the verdict answers
    # before the crossed control ever matters. The crossed-target fence itself
    # is proved on a candidate that IS shareable, below.
    assert PublicationCustody.approve(crossed) == {:error, :publication_not_publishable}
  end

  test "review mutations reconcile exact generations, revisions, leases, policy, and patch bytes" do
    %{claim: claim, offer: offer, offer_receipt: receipt} = delivered_offer!("review-fences")
    request = review_request(offer, receipt)

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
    %{offer: offer, offer_receipt: receipt} = delivered_offer!("recover-retry")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(offer, receipt))

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

  # A review phase can fail permanently: reconciliation reads its operation on the placement that
  # owns it, and once that placement is replaced no retry can ever clear the error. Before this,
  # review_pending had no update or discard clause, so the publication deferred once a minute
  # forever. Update must queue a fresh review generation, and only for a phase that actually failed.
  test "operator update queues a fresh review for a review phase no retry can clear" do
    %{offer: offer, offer_receipt: receipt} =
      delivered_offer!("recover-stuck-review")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(offer, receipt))

    assert PublicationCustody.recover(publication.ref, :update, 1) ==
             {:error, :publication_recovery_not_allowed}

    assert {:ok, active} = PublicationCustody.claim_next("publication:recover-stuck", 60)

    assert {:ok, _deferred} =
             PublicationCustody.defer(
               publication.ref,
               active.lease_ref,
               300,
               "coop_session_replacement_required",
               ~s({:coop_session_replacement_required, "session", 1})
             )

    assert {:ok, %{previous: previous, publication: updated}} =
             PublicationCustody.recover(publication.ref, :update, 1)

    assert previous == %{
             "last_error_code" => "coop_session_replacement_required",
             "recovery_generation" => 1,
             "status" => "review_pending"
           }

    assert updated.status == :review_pending
    assert updated.review_generation == publication.review_generation + 1
    assert updated.recovery_generation == 2
    assert updated.review_expected_revision == nil
    assert updated.last_error_code == nil
    assert updated.last_error_detail == nil
    assert updated.lease_ref == nil
    assert %DateTime{} = updated.next_attempt_at

    assert PublicationCustody.recover(publication.ref, :update, 1) ==
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

  # Every confirmed coding task used to stop here and ask a person to press
  # "Create draft PR" on a candidate the host had already reviewed under the
  # authority that person granted when they confirmed the task. The click bought
  # nothing: it could not change the candidate, the repository or the scope.
  test "a reviewed candidate under a confirmed task's own grant becomes a draft with no click" do
    %{claim: claim, publication: publication} =
      task_reviewed_publication!("auto-draft", confirmed_repository: "responder")

    assert publication.status == :publish_pending,
           "an authorized reviewed candidate must not wait for a publication click"

    assert publication.approval_ref == "host:publication:draft:#{publication.id}"
    assert publication.approved_by_actor_ref == "slack:user:U-confirmer"
    assert publication.approved_at

    # The grant is the person's, carried from the task they confirmed. Nothing
    # here is a merge, deployment or cross-repository permission.
    assert publication.repository == "responder"

    assert {:ok, publish_claim} = PublicationCustody.claim_next("publication:auto-draft", 60)
    assert publish_claim.publication.id == publication.id

    # A replayed operator approval reconciles to the same publication instead of
    # opening a second pull request for the same work.
    assert {:ok, %{status: :duplicate, publication: same}} =
             PublicationCustody.approve(%{
               actor_ref: "slack:user:U-confirmer",
               approval_ref: publication.approval_ref,
               occurred_at: publication.approved_at,
               publication_ref: publication.ref,
               target: %{
                 conversation_ref: claim.episode.destination_conversation_ref,
                 message_ref: publication.review_delivery_receipt["message_ref"],
                 thread_ref: claim.episode.destination_thread_ref,
                 transport: "slack"
               }
             })

    assert same.id == publication.id

    assert [_one] =
             Repo.all(from(p in Publication, where: p.episode_id == ^claim.episode.id))
  end

  test "a revoked or differently scoped task grant leaves publication to a person" do
    %{publication: revoked} =
      task_reviewed_publication!("revoked-grant",
        confirmed_repository: "responder",
        task_status: :superseded
      )

    assert revoked.status == :reviewed
    assert revoked.approval_ref == nil

    %{publication: crossed} =
      task_reviewed_publication!("crossed-grant", confirmed_repository: "other-service")

    assert crossed.status == :reviewed,
           "a task confirmed for another repository grants nothing here"

    assert crossed.approval_ref == nil

    %{publication: unconfirmed} = task_reviewed_publication!("no-task", confirmed_repository: nil)
    assert unconfirmed.status == :reviewed
    assert unconfirmed.approval_ref == nil
  end

  test "an operator's discard is the last word on publishing that candidate" do
    %{claim: claim, publication: blocked} =
      task_reviewed_publication!("no-pr",
        confirmed_repository: "responder",
        gate: "startup_error"
      )

    # Checks could not run, so the host never publishes on its own; the safe
    # snapshot is offered to a person instead.
    assert blocked.status == :blocked
    assert blocked.approval_ref == nil
    assert blocked.review_patch

    assert {:ok, %{publication: discarded}} =
             PublicationCustody.recover(blocked.ref, :discard, blocked.recovery_generation)

    assert discarded.status == :discarded

    approval = %{
      actor_ref: "slack:user:U-confirmer",
      approval_ref: "interaction:publish:no-pr",
      occurred_at: DateTime.add(@now, 3, :second),
      publication_ref: blocked.ref,
      target: %{
        conversation_ref: claim.episode.destination_conversation_ref,
        message_ref: blocked.review_delivery_receipt["message_ref"],
        thread_ref: claim.episode.destination_thread_ref,
        transport: "slack"
      }
    }

    assert PublicationCustody.approve(approval) == {:error, :publication_not_reviewed}
    assert Repo.get!(Publication, blocked.id).status == :discarded
  end

  test "a safe snapshot whose checks could not run is offered, never published automatically" do
    %{claim: claim, publication: blocked} =
      task_reviewed_publication!("checks-unavailable",
        confirmed_repository: "responder",
        gate: "startup_error"
      )

    assert blocked.status == :blocked
    assert blocked.approval_ref == nil

    # "Checkpointing is preservation, not evidence that a gate passed": the
    # exact snapshot survives so a person can read it, and the missing check
    # stays missing.
    assert blocked.review_patch == "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"
    refute Review.publishable?(blocked.review_document)
    assert Review.draft_shareable?(blocked.review_document)

    approval = %{
      actor_ref: "slack:user:U-confirmer",
      approval_ref: "interaction:publish:checks-unavailable",
      occurred_at: DateTime.add(@now, 3, :second),
      publication_ref: blocked.ref,
      target: %{
        conversation_ref: claim.episode.destination_conversation_ref,
        message_ref: blocked.review_delivery_receipt["message_ref"],
        thread_ref: claim.episode.destination_thread_ref,
        transport: "slack"
      }
    }

    assert PublicationCustody.approve(put_in(approval, [:target, :message_ref], "message:other")) ==
             {:error, :publication_review_delivery_mismatch}

    assert {:ok, %{status: :approved, publication: approved}} =
             PublicationCustody.approve(approval)

    assert approved.status == :publish_pending
  end

  test "a failed gate or a policy finding can never be shared as a draft" do
    for {suffix, overrides} <- [
          {"gate-failed", %{gate: "failed"}},
          {"policy-finding", %{gate: "passed", policy_findings: ["A secret was written."]}}
        ] do
      %{claim: claim, publication: blocked} =
        task_reviewed_publication!(
          suffix,
          Keyword.merge([confirmed_repository: "responder"], Map.to_list(overrides))
        )

      assert blocked.status == :blocked
      assert blocked.review_patch == nil, "an unshareable candidate retains no snapshot"

      assert PublicationCustody.approve(%{
               actor_ref: "slack:user:U-confirmer",
               approval_ref: "interaction:publish:#{suffix}",
               occurred_at: DateTime.add(@now, 3, :second),
               publication_ref: blocked.ref,
               target: %{
                 conversation_ref: claim.episode.destination_conversation_ref,
                 message_ref: blocked.review_delivery_receipt["message_ref"],
                 thread_ref: claim.episode.destination_thread_ref,
                 transport: "slack"
               }
             }) == {:error, :publication_not_publishable}
    end
  end

  # A correction reached nothing. Readiness refused a second publication for an
  # episode that already had one, so the corrected candidate never ran its
  # checks and never reached the pull request the host had already opened: the
  # operator's only routes back were "Review latest state" or retyping the whole
  # task. The task's own publication and its PR are what the correction belongs
  # to, so re-arm them for a fresh review instead of minting a second draft.
  test "a corrected candidate re-arms the task's own publication and keeps its pull request" do
    %{claim: claim} = task_episode!("rearm")
    %{claim: first} = corrected_candidate!(claim, "rearm", "one")
    published = publish_task_publication!(first, "rearm", "one")

    assert published.status == :published
    assert published.pull_request_number == 91

    correction = corrected_candidate!(first, "rearm", "two")
    turn = correction.turn

    assert [rearmed] =
             Repo.all(from(p in Publication, where: p.episode_id == ^claim.episode.id))

    assert rearmed.id == published.id
    assert rearmed.status == :review_pending

    assert rearmed.review_generation == published.review_generation + 1,
           "a corrected candidate asks Coop a new question, not the frozen one"

    assert rearmed.recovery_generation == published.recovery_generation + 1
    assert rearmed.review_request_ref == "task-readiness:#{turn.id}"
    assert rearmed.review_requested_at == turn.accepted_at
    assert rearmed.review_requested_by_actor_ref == "slack:user:U-confirmer"
    assert rearmed.session_id == correction.claim.session.id
    assert is_nil(rearmed.lease_ref)
    assert %DateTime{} = rearmed.next_attempt_at

    # The pull request Responder owns is retained, so the corrected candidate
    # updates it instead of opening a second one.
    assert rearmed.pull_request_number == published.pull_request_number
    assert rearmed.pull_request_url == published.pull_request_url
    assert rearmed.branch_ref == published.branch_ref
    assert rearmed.commit_sha == published.commit_sha
    assert rearmed.github_repository == published.github_repository
    assert is_nil(rearmed.expected_remote_head_sha)

    # The superseded generation's approval and publication receipt cannot carry
    # a new candidate; the PR itself and the review history stay.
    assert is_nil(rearmed.approval_ref)
    assert is_nil(rearmed.approved_by_actor_ref)
    assert is_nil(rearmed.publication_receipt)
    assert is_nil(rearmed.published_at)
    assert is_nil(rearmed.published_delivery_receipt)
    assert is_nil(rearmed.review_document)
    assert is_nil(rearmed.review_patch)
    assert is_nil(rearmed.review_delivery_receipt)

    # Accepting the same result twice arms one review, not two.
    assert {:ok, _duplicate} = reaccept!(correction)
    assert Repo.get!(Publication, rearmed.id).review_generation == rearmed.review_generation

    assert Repo.aggregate(
             from(p in Publication, where: p.episode_id == ^claim.episode.id),
             :count
           ) == 1
  end

  # Two review generations of one publication are two facts, not one. The
  # delivery ref named only the publication, and a repeat delivery ref
  # reconciles onto the message that already carries it, so a fresh review
  # landed silently on the superseded card and told the operator nothing.
  test "each review generation delivers its own card" do
    reviewed = reviewed_publication!("review-card-generations", true)

    assert {:ok, %{publication: updated}} =
             PublicationCustody.recover(reviewed.ref, :update, 1)

    assert updated.review_generation == reviewed.review_generation + 1

    assert {:ok, claim} =
             PublicationCustody.claim_next("publication:review-card-generations:2", 60)

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(reviewed.ref, claim.lease_ref, 7)

    patch = "diff --git a/lib/fix.ex b/lib/fix.ex\n+corrected\n"

    review =
      %{
        episode: %{id: reviewed.episode_id},
        session: Repo.get!(Session, reviewed.session_id)
      }
      |> review_document()
      |> Map.merge(%{
        "patch_artifact_id" => "review-patch:review-card-generations:2",
        "patch_bytes" => byte_size(patch),
        "patch_digest" => digest(patch)
      })

    assert {:ok, ready} =
             PublicationCustody.store_review(
               reviewed.ref,
               claim.lease_ref,
               frozen.review_generation,
               review,
               patch
             )

    assert ready.status == :review_ready

    assert {:ok, delivery_claim} =
             PublicationCustody.claim_next("publication:review-card-generations:delivery", 60)

    assert {:ok, request} = PublicationCustody.delivery_request(delivery_claim.publication)
    assert request.ref == "publication-review:#{reviewed.id}:g2"

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               request.ref,
               request.transport,
               request.conversation_ref,
               request.thread_ref,
               "message:review-card-generations:2"
             )

    assert {:ok, delivered} =
             PublicationCustody.confirm_delivery(reviewed.ref, delivery_claim.lease_ref, receipt)

    assert delivered.review_delivery_receipt["message_ref"] ==
             "message:review-card-generations:2"

    refute delivered.review_delivery_receipt["message_ref"] ==
             reviewed.review_delivery_receipt["message_ref"]
  end

  # A head that moved outside this publication is not the correction's to fix:
  # nothing the agent commits can reconcile a branch somebody else pushed. That
  # is why "Review latest state" is retained — it is the operator's explicit
  # decision to review against the moved head.
  test "a corrected candidate never re-arms a publication whose head moved outside it" do
    %{claim: claim} = task_episode!("moved-head")
    %{claim: first} = corrected_candidate!(claim, "moved-head", "one")
    published = publish_task_publication!(first, "moved-head", "one")
    observed = String.duplicate("d", 40)

    # Exactly what the follow-up poller records when the PR head is no longer
    # the commit this publication pushed.
    stale =
      published
      |> PublicationChangeset.update(%{expected_remote_head_sha: observed})
      |> Repo.update!()

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^published.id),
      set: [pr_state: "stale"]
    )

    %{claim: _second} = corrected_candidate!(first, "moved-head", "two")

    assert [untouched] =
             Repo.all(from(p in Publication, where: p.episode_id == ^claim.episode.id))

    assert untouched.id == published.id
    assert untouched.status == :published
    assert untouched.expected_remote_head_sha == observed
    assert untouched.review_generation == stale.review_generation
    assert untouched.review_request_ref == stale.review_request_ref

    # The retained operator control is still the route through a moved head.
    assert {:ok, %{publication: recovered}} =
             PublicationCustody.recover(untouched.ref, :update, untouched.recovery_generation)

    assert recovered.status == :review_pending
    assert recovered.pull_request_number == published.pull_request_number
  end

  test "a corrected candidate never resurrects a discarded publication" do
    %{claim: claim} = task_episode!("discarded")
    %{claim: first} = corrected_candidate!(claim, "discarded", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    blocked = review_task_publication!(publication, first, "discarded", "one", gate: "failed")
    assert blocked.status == :blocked

    assert {:ok, %{publication: discarded}} =
             PublicationCustody.recover(blocked.ref, :discard, blocked.recovery_generation)

    assert discarded.status == :discarded

    corrected_candidate!(first, "discarded", "two")

    assert [still_discarded] =
             Repo.all(from(p in Publication, where: p.episode_id == ^claim.episode.id))

    assert still_discarded.id == blocked.id
    assert still_discarded.status == :discarded
    assert still_discarded.review_generation == discarded.review_generation
    assert still_discarded.recovery_generation == discarded.recovery_generation
  end

  # The pull request lives in the publication's own repository, which is not
  # always the session's: an operator-requested publication takes it from the
  # episode's repository-write goal. Re-arming across that boundary would hand
  # one repository's exact PR number to another repository's App binding.
  test "a corrected candidate never re-arms a publication bound to another repository" do
    %{claim: claim} = task_episode!("crossed-repository")
    %{claim: first} = corrected_candidate!(claim, "crossed-repository", "one")
    published = publish_task_publication!(first, "crossed-repository", "one")

    crossed =
      published
      |> PublicationChangeset.update(%{repository: "other-service"})
      |> Repo.update!()

    corrected_candidate!(first, "crossed-repository", "two")

    assert [untouched] =
             Repo.all(from(p in Publication, where: p.episode_id == ^claim.episode.id))

    assert untouched.id == crossed.id
    assert untouched.status == :published
    assert untouched.review_generation == crossed.review_generation
  end

  # A correction can be accepted while the publication is already opening its
  # draft. Re-arming there would race the publisher against a candidate it is
  # mid-push, so a running phase keeps the publication it holds.
  test "a corrected candidate never disturbs a publication phase that is still running" do
    %{claim: claim} = task_episode!("in-flight")
    %{claim: first} = corrected_candidate!(claim, "in-flight", "one")

    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    authorized = review_task_publication!(publication, first, "in-flight", "one")
    assert authorized.status == :publish_pending

    corrected_candidate!(first, "in-flight", "two")

    assert [held] = Repo.all(from(p in Publication, where: p.episode_id == ^claim.episode.id))
    assert held.id == authorized.id
    assert held.status == :publish_pending
    assert held.review_generation == authorized.review_generation
    assert held.approval_ref == authorized.approval_ref
  end

  # One confirmed engineering task on its own episode: the task record settles
  # on the first turn, and the session carries the workspace task that makes
  # every later completed turn a candidate for this task's own publication.
  defp task_episode!(suffix) do
    %{claim: claim, task: task} =
      delivered_offer!(suffix, repository: "responder", task_repository: "responder")

    confirm_task!(task, claim, suffix, confirmed_repository: "responder")

    session =
      Repo.get!(Session, claim.session.id)
      |> SessionChangeset.bind_workspace_task(%{
        "offer_ref" => task.ref,
        "prompt" => "Implement #{suffix} and run the focused checks.",
        "title" => "Implement #{suffix}"
      })
      |> Repo.update!()

    %{claim: %{claim | session: session}, task: task}
  end

  # One accepted completed turn carrying the host's own `host:publication:ready`
  # offer, exactly as `Work.Executor` writes it after a checkpointed workspace.
  defp corrected_candidate!(claim, suffix, label) do
    admit_followup!(claim, label)
    assert {:ok, work} = Custody.claim_next("work:#{suffix}:#{label}", 60, :work)
    work = bind_remote!(work)

    assert {:ok, _offer} =
             Records.create(
               Records.token(work.turn),
               "host:publication:ready",
               "publication_offer",
               %{
                 "body" => "Corrected #{suffix} on the #{label} pass.",
                 "title" => "Implement #{suffix}"
               }
             )

    final = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The #{label} correction is committed.",
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
    }

    candidate = Jason.encode!(final)
    candidate_sha256 = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, final)

    assert {:ok, _intent} =
             Custody.prepare_validation(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               work.lease_ref,
               candidate_sha256,
               1,
               "validation:#{work.turn.id}"
             )

    assert {:ok, delivery} =
             Custody.claim_next("delivery:#{suffix}:#{label}", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               work.episode.destination_conversation_ref,
               work.episode.destination_thread_ref,
               "message:#{suffix}:#{label}:reply"
             )

    assert {:ok, _settled} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery.lease_ref,
               receipt
             )

    %{claim: work, sha256: candidate_sha256, turn: accepted.turn}
  end

  defp reaccept!(%{claim: work, sha256: sha256}) do
    Custody.accept_result(
      work.episode.id,
      work.episode.key,
      work.turn.turn_ref,
      work.lease_ref,
      sha256,
      1,
      "validation:#{work.turn.id}"
    )
  end

  defp publish_task_publication!(claim, suffix, label) do
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    authorized = review_task_publication!(publication, claim, suffix, label)

    assert {:ok, publish_claim} =
             PublicationCustody.claim_next("publication:#{suffix}:#{label}:publish", 60)

    receipt = %{
      "branch_ref" => "refs/heads/responder/#{publication.id}",
      "candidate_tree" => authorized.review_document["candidate_tree"],
      "commit_sha" => String.duplicate("9", 40),
      "pull_request_number" => 91,
      "pull_request_url" => "https://github.com/acme/responder/pull/91",
      "repository" => "responder"
    }

    assert {:ok, %Publication{status: :published_ready}} =
             PublicationCustody.store_publication(
               publication.ref,
               publish_claim.lease_ref,
               receipt
             )

    assert {:ok, result_claim} =
             PublicationCustody.claim_next("publication:#{suffix}:#{label}:result", 60)

    assert {:ok, result_request} =
             PublicationCustody.delivery_request(result_claim.publication)

    assert {:ok, result_receipt} =
             DeliveryReceipt.new(
               result_request.ref,
               result_request.transport,
               result_request.conversation_ref,
               result_request.thread_ref,
               "message:#{suffix}:#{label}:published"
             )

    assert {:ok, published} =
             PublicationCustody.confirm_delivery(
               publication.ref,
               result_claim.lease_ref,
               result_receipt
             )

    published
  end

  defp review_task_publication!(publication, claim, suffix, label, options \\ []) do
    assert {:ok, review_claim} =
             PublicationCustody.claim_next("publication:#{suffix}:#{label}:review", 60)

    assert review_claim.publication.id == publication.id

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(publication.ref, review_claim.lease_ref, 7)

    gate = Keyword.get(options, :gate, "passed")
    publishable? = gate == "passed"
    patch = if publishable?, do: "diff --git a/lib/fix.ex b/lib/fix.ex\n+#{label}\n"

    review =
      claim
      |> review_document()
      |> Map.merge(%{
        "gate" => gate,
        "not_publishable_reasons" => if(publishable?, do: [], else: ["The checks did not pass."]),
        "patch_artifact_id" => "review-patch:#{suffix}:#{label}",
        "patch_bytes" => if(patch, do: byte_size(patch), else: 0),
        "patch_digest" => if(patch, do: digest(patch), else: nil),
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
             PublicationCustody.claim_next("publication:#{suffix}:#{label}:delivery", 60)

    assert {:ok, request} = PublicationCustody.delivery_request(delivery_claim.publication)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               request.ref,
               request.transport,
               request.conversation_ref,
               request.thread_ref,
               "message:#{suffix}:#{label}:review"
             )

    assert {:ok, authorized} =
             PublicationCustody.confirm_delivery(
               publication.ref,
               delivery_claim.lease_ref,
               receipt
             )

    authorized
  end

  defp task_reviewed_publication!(suffix, options) do
    %{claim: claim, offer: offer, offer_receipt: receipt, task: task} =
      delivered_offer!(suffix, task_repository: Keyword.fetch!(options, :confirmed_repository))

    confirm_task!(task, claim, suffix, options)

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(offer, receipt))

    assert {:ok, review_claim} = PublicationCustody.claim_next("publication:#{suffix}", 60)

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(publication.ref, review_claim.lease_ref, 7)

    gate = Keyword.get(options, :gate, "passed")
    findings = Keyword.get(options, :policy_findings, [])
    shareable? = gate != "failed" and findings == []
    patch = if shareable?, do: "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"

    review =
      claim
      |> review_document()
      |> Map.merge(%{
        "gate" => gate,
        "not_publishable_reasons" =>
          if(gate == "passed" and findings == [], do: [], else: ["The checks did not pass."]),
        "patch_bytes" => if(patch, do: byte_size(patch), else: 0),
        "patch_digest" => if(patch, do: digest(patch), else: nil),
        "policy_findings" => findings,
        "publishable" => gate == "passed" and findings == []
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

    %{claim: claim, publication: publication, review_request: request}
  end

  # The publication's own episode is the task episode; its grant lives on the
  # task_offer record a person confirmed in the conversation that proposed it.
  # The real parent/child confirmation path is exercised end to end in
  # `Responder.Slack.TaskEndToEndTest`.
  defp confirm_task!(nil, _claim, _suffix, _options), do: :ok

  defp confirm_task!(task, claim, suffix, options) do
    confirmation =
      case Keyword.get(options, :task_status, :confirmed) do
        :confirmed ->
          [
            confirmation_ref: "interaction:confirm:#{suffix}",
            confirmed_at: @now,
            confirmed_by_actor_ref: "slack:user:U-confirmer",
            confirmed_episode_id: claim.episode.id,
            status: :confirmed
          ]

        revoked ->
          [status: revoked]
      end

    {1, _rows} =
      Repo.update_all(
        from(record in Responder.State.Record, where: record.id == ^task.id),
        set: confirmation
      )

    :ok
  end

  defp admit_followup!(claim, label \\ "one") do
    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: claim.episode.destination_conversation_ref,
          thread_ref: claim.episode.destination_thread_ref,
          transport: claim.episode.destination_transport
        },
        episode_id: claim.episode.id,
        episode_key: claim.episode.key,
        native_input_id: "followup:#{label}:#{claim.episode.id}",
        occurred_at: DateTime.utc_now(),
        payload: %{"text" => "Please include the follow-up correction."},
        turn_ref: "turn:followup:#{label}:#{claim.episode.id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    command
  end

  defp reviewed_publication!(suffix, publishable?) do
    %{claim: claim, offer: offer, offer_receipt: receipt} = delivered_offer!(suffix)

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(offer, receipt))

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

  defp delivered_offer!(suffix, options \\ []) do
    claim = claim_episode!(suffix, Keyword.get(options, :repository))

    delivery_thread_ref =
      Keyword.get(options, :delivery_thread_ref, claim.episode.destination_thread_ref)

    task = task_offer!(claim, suffix, Keyword.get(options, :task_repository))

    assert {:ok, _goal} =
             Records.create(Records.token(claim.turn), "goal-#{suffix}", "goal", %{
               "authority" => "repository_write",
               "completion_contract" => "The implementation is committed and reviewed.",
               "id" => "engineering-#{suffix}",
               "kind" => "engineering",
               "requested_outcome" => "Implement #{suffix}",
               "required" => true,
               "stage" => "implementation",
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

    # Where this turn's reply goes, exactly as `Custody.reply_target/2` freezes
    # it at acceptance: the answering input's own origin, which routing can join
    # into this episode from a thread other than its bound home.
    Repo.get_by!(Turn, episode_id: claim.episode.id, turn_ref: claim.turn.turn_ref)
    |> Ecto.Changeset.change(
      delivery_target: %{
        "conversation_ref" => claim.episode.destination_conversation_ref,
        "thread_ref" => delivery_thread_ref,
        "transport" => "slack"
      }
    )
    |> Repo.update!()

    assert {:ok, offer_receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               claim.episode.destination_conversation_ref,
               delivery_thread_ref,
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

    %{claim: claim, offer: offer, offer_receipt: offer_receipt, task: task}
  end

  defp task_offer!(_claim, _suffix, nil), do: nil

  defp task_offer!(claim, suffix, repository) do
    assert {:ok, task} =
             Records.create(Records.token(claim.turn), "task-#{suffix}", "task_offer", %{
               "kind" => "engineering",
               "prompt" => "Implement #{suffix} and run the focused checks.",
               "repository" => repository,
               "title" => "Implement #{suffix}"
             })

    task
  end

  defp claim_episode!(suffix, repository) do
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
             Custody.pin_episode(id, "work-contributor", String.duplicate("a", 64), repository)

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

  defp review_request(offer, receipt) do
    %{
      actor_ref: "slack:user:U-operator",
      occurred_at: DateTime.add(@now, 1, :second),
      record_ref: offer.ref,
      request_ref: "interaction:review:#{offer.id}",
      target: %{
        conversation_ref: receipt["conversation_ref"],
        message_ref: receipt["message_ref"],
        thread_ref: receipt["thread_ref"],
        transport: receipt["transport"]
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
