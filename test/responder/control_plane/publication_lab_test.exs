defmodule Responder.ControlPlane.PublicationLabTest do
  use Responder.DataCase, async: true

  alias Responder.ControlPlane.{Actions, Projection, Publisher}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.WorkProfile
  alias Responder.Publication.{Changeset, Publication}
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.Repo
  alias Responder.State.Records

  alias Responder.Work.{Custody, DeliveryReceipt, Result, SubmissionBuilder}

  @conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
  @now ~U[2026-08-30 18:00:00.000000Z]
  @digest String.duplicate("a", 64)
  @git String.duplicate("b", 40)

  test "a Lab publication offer reaches review and explicit publish approval in the same conversation" do
    fixture = delivered_publication_offer!()
    actions = Actions.callbacks(profile(), %{})

    assert {:ok, requested} =
             actions.act_on_lab_record.(
               @conversation_id,
               fixture.record.ref,
               :review_publication,
               nil
             )

    assert requested.status == :requested
    assert requested.publication.repository == "responder"
    assert requested.publication.status == :review_pending

    review = %{
      "candidate_tree" => @git,
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "patch_bytes" => 4_096,
      "patch_digest" => @digest,
      "policy_findings" => [],
      "publishable" => true,
      "rebase" => "clean"
    }

    requested.publication
    |> Changeset.update(%{
      review_document: review,
      review_fingerprint: digest(review),
      review_patch: "diff --git a/lib/a.ex b/lib/a.ex",
      reviewed_at: DateTime.add(@now, 2, :second),
      status: :review_ready
    })
    |> Repo.update!()

    assert {:ok, publication_claim} =
             PublicationCustody.claim_next("lab-publication-review", 60)

    assert publication_claim.publication.id == requested.publication.id
    assert {:ok, request} = PublicationCustody.delivery_request(publication_claim.publication)
    assert {:ok, receipt} = Publisher.publish_message(request, nil)

    assert {:ok, %Publication{status: :reviewed}} =
             PublicationCustody.confirm_delivery(
               requested.publication.ref,
               publication_claim.lease_ref,
               receipt
             )

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)

    assert review_message =
             Enum.find(conversation.messages, fn message ->
               Enum.any?(message.cards, &(&1.kind == "publication_review"))
             end)

    assert [review_card] = review_message.cards
    assert review_card.ref == fixture.record.ref
    assert review_card.status == :reviewed
    assert review_card.action == :approve_publication
    assert {"Gate", "passed"} in review_card.details
    assert review_message.text =~ "passed trusted review"

    assert {:ok, approved} =
             actions.act_on_lab_record.(
               @conversation_id,
               fixture.record.ref,
               :approve_publication,
               nil
             )

    assert approved.status == :approved
    assert approved.publication.status == :publish_pending

    assert actions.act_on_lab_record.(
             "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7",
             fixture.record.ref,
             :approve_publication,
             nil
           ) == {:error, :conversation_lab_record_mismatch}
  end

  test "a confirmed Lab task exposes the same trusted readiness control as its Slack card" do
    task_offer = delivered_task_offer!()

    actions =
      Actions.callbacks(profile(), %{
        "responder" => %{name: "responder-contributor", digest: @digest}
      })

    assert {:ok, confirmation} =
             actions.act_on_lab_record.(@conversation_id, task_offer.ref, :confirm_task, nil)

    assert {:ok, child_claim} = Custody.claim_next("lab-task-readiness", 60, :work)
    assert child_claim.episode.id == confirmation.episode.id
    child_claim = bind_claim!(child_claim, "task-readiness")

    assert {:ok, publication_offer} =
             Records.create(
               Records.token(child_claim.turn),
               "host:publication:ready",
               "publication_offer",
               %{
                 "body" => "Review the exact candidate before publishing a draft pull request.",
                 "title" => "Finish Conversation Lab parity"
               }
             )

    settle_claim!(
      child_claim,
      %{
        "message" => "The exact candidate is ready for trusted review.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      },
      "control-plane-message:task-readiness"
    )

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)

    task_card =
      conversation.messages
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.ref == task_offer.ref))

    assert :request_task_readiness in task_card.actions

    assert {:ok, readiness} =
             actions.act_on_lab_record.(
               @conversation_id,
               task_offer.ref,
               :request_task_readiness,
               nil
             )

    assert readiness.status == :requested
    assert readiness.publication.record_id == publication_offer.id
    assert readiness.publication.episode_id == confirmation.episode.id
    assert readiness.publication.destination_transport == "control_plane"
    assert readiness.publication.destination_conversation_ref == conversation_ref()

    assert {:ok, review_claim} = PublicationCustody.claim_next("lab-task-review", 60)

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(
               readiness.publication.ref,
               review_claim.lease_ref,
               7
             )

    patch = "diff --git a/lib/lab.ex b/lib/lab.ex\n+publication parity\n"
    review = review_document("coop-session:task-readiness", confirmation.episode.id, patch)

    assert {:ok, %{status: :review_ready}} =
             PublicationCustody.store_review(
               readiness.publication.ref,
               review_claim.lease_ref,
               frozen.review_generation,
               review,
               patch
             )

    assert {:ok, review_delivery_claim} =
             PublicationCustody.claim_next("lab-task-review-delivery", 60)

    assert {:ok, review_request} =
             PublicationCustody.delivery_request(review_delivery_claim.publication)

    assert {:ok, review_receipt} = Publisher.publish_message(review_request, nil)

    assert {:ok, %Publication{status: :reviewed}} =
             PublicationCustody.confirm_delivery(
               readiness.publication.ref,
               review_delivery_claim.lease_ref,
               review_receipt
             )

    assert {:ok, reviewed_conversation} = Projection.lab_conversation(@conversation_id)

    reviewed_task =
      reviewed_conversation.messages
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.ref == task_offer.ref))

    assert :approve_task_publication in reviewed_task.actions

    assert {:ok, approval} =
             actions.act_on_lab_record.(
               @conversation_id,
               task_offer.ref,
               :approve_task_publication,
               nil
             )

    assert approval.status == :approved
    assert approval.publication.status == :publish_pending

    assert {:ok, publish_claim} = PublicationCustody.claim_next("lab-task-publish", 60)

    publication_receipt = %{
      "branch_ref" => "refs/heads/responder/lab-parity",
      "candidate_tree" => review["candidate_tree"],
      "commit_sha" => String.duplicate("c", 40),
      "pull_request_number" => 42,
      "pull_request_url" => "https://github.com/example/responder/pull/42",
      "repository" => "responder"
    }

    assert {:ok, %{status: :published_ready}} =
             PublicationCustody.store_publication(
               readiness.publication.ref,
               publish_claim.lease_ref,
               publication_receipt
             )

    assert {:ok, result_delivery_claim} =
             PublicationCustody.claim_next("lab-task-result-delivery", 60)

    assert {:ok, result_request} =
             PublicationCustody.delivery_request(result_delivery_claim.publication)

    assert {:ok, result_receipt} = Publisher.publish_message(result_request, nil)

    assert {:ok, %Publication{status: :published}} =
             PublicationCustody.confirm_delivery(
               readiness.publication.ref,
               result_delivery_claim.lease_ref,
               result_receipt
             )

    assert {:ok, published_conversation} = Projection.lab_conversation(@conversation_id)

    published_task =
      published_conversation.messages
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.ref == task_offer.ref))

    assert :check_task_publication in published_task.actions
    assert published_task.url == "https://github.com/example/responder/pull/42"

    assert {:ok, check} =
             actions.act_on_lab_record.(
               @conversation_id,
               task_offer.ref,
               :check_task_publication,
               nil
             )

    assert check.status == :requested
  end

  defp delivered_task_offer! do
    conversation_ref = conversation_ref()
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:lab-task-offer:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: conversation_ref,
                   transport: "control_plane"
                 },
                 episode_id: episode_id,
                 episode_key: "lab-task-offer:#{episode_id}",
                 native_input_id: "lab-task-offer-input:#{episode_id}",
                 occurred_at: @now,
                 payload: %{"text" => "Prepare a reviewed repository change."},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, profile().policy, profile().policy_digest)

    assert {:ok, claim} = Custody.claim_next("lab-task-offer", 60, :work)
    claim = bind_claim!(claim, "task-offer")

    assert {:ok, task_offer} =
             Records.create(Records.token(claim.turn), "task-offer", "task_offer", %{
               "kind" => "engineering",
               "prompt" => "Implement the approved Conversation Lab parity change.",
               "repository" => "responder",
               "title" => "Finish Conversation Lab parity"
             })

    settle_claim!(
      claim,
      %{
        "message" => "I prepared a repository task for confirmation.",
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [task_offer.ref],
          "state" => "complete"
        }
      },
      "control-plane-message:task-offer"
    )

    task_offer
  end

  defp bind_claim!(claim, suffix) do
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, _turn} =
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
               "coop-session:#{suffix}"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{suffix}"
             )

    claim
  end

  defp settle_claim!(claim, document, message_ref) do
    candidate = Jason.encode!(document)
    candidate_sha = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha,
               1
             )

    assert {:ok, result} = Result.new(:reply, document)

    assert {:ok, _turn} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               candidate_sha,
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
               candidate_sha,
               1,
               "validation-receipt:#{message_ref}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:#{message_ref}", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "control_plane",
               conversation_ref(),
               conversation_ref(),
               message_ref
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    settled
  end

  defp delivered_publication_offer! do
    conversation_ref = conversation_ref()
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:lab-publication:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: conversation_ref,
                   transport: "control_plane"
                 },
                 episode_id: episode_id,
                 episode_key: "lab-publication:#{episode_id}",
                 native_input_id: "lab-publication-input:#{episode_id}",
                 occurred_at: @now,
                 payload: %{"text" => "Prepare an exact reviewed draft change."},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, session} =
             Repo.transaction(fn ->
               {:ok, session} =
                 Responder.Work.Custody.pin_task_episode_in_transaction(
                   episode_id,
                   "responder-contributor",
                   @digest,
                   "responder",
                   %{
                     "authority_limits" => [],
                     "instruction_ref" => "lab-publication",
                     "offer_ref" => "lab-publication",
                     "prompt" => "Prepare an exact reviewed draft change.",
                     "source_refs" => [],
                     "success_checks" => ["Focused tests pass."],
                     "title" => "Prepare Lab publication"
                   }
                 )

               session
             end)

    assert {:ok, claim} =
             Responder.Work.Custody.claim_next("lab-publication-work", 60, :work)

    assert {:ok, record} =
             Records.create(
               Records.token(claim.turn),
               "publication-offer",
               "publication_offer",
               %{
                 "body" => "Publish the exact reviewed candidate as a draft pull request.",
                 "title" => "Finish Conversation Lab parity"
               }
             )

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, _turn} =
             Responder.Work.Custody.freeze_submission(
               episode_id,
               turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, bound_session} =
             Responder.Work.Custody.bind_session(
               episode_id,
               turn_ref,
               claim.lease_ref,
               session.generation,
               session.create_generation,
               "coop-session:lab-publication"
             )

    assert {:ok, _turn} =
             Responder.Work.Custody.bind_turn(
               episode_id,
               turn_ref,
               claim.lease_ref,
               bound_session.generation,
               claim.turn.submit_generation,
               "coop-turn:lab-publication"
             )

    document = %{
      "message" => "The exact candidate is ready for trusted review.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [record.ref],
        "state" => "complete"
      }
    }

    candidate = Jason.encode!(document)
    candidate_sha = digest(candidate)

    assert {:ok, _turn} =
             Responder.Work.Custody.stage_candidate(
               episode_id,
               turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha,
               1
             )

    assert {:ok, result} = Result.new(:reply, document)

    assert {:ok, _turn} =
             Responder.Work.Custody.prepare_validation(
               episode_id,
               turn_ref,
               claim.lease_ref,
               candidate_sha,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Responder.Work.Custody.accept_result(
               episode_id,
               transition.episode.key,
               turn_ref,
               claim.lease_ref,
               candidate_sha,
               1,
               "validation-receipt:lab-publication"
             )

    assert {:ok, delivery_claim} =
             Responder.Work.Custody.claim_next("lab-publication-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "control_plane",
               conversation_ref,
               conversation_ref,
               "control-plane-message:lab-publication"
             )

    assert {:ok, _settled} =
             Responder.Work.Custody.confirm_delivery(
               episode_id,
               transition.episode.key,
               turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{record: record}
  end

  defp profile do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: @digest,
        repository_ref: nil
      })

    profile
  end

  defp conversation_ref, do: "control-plane:lab:#{@conversation_id}"

  defp review_document(session_id, episode_id, patch) do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "lab-review-#{episode_id}",
      "parent_head" => String.duplicate("4", 40),
      "parent_tree" => String.duplicate("5", 40),
      "patch_artifact_id" => "lab-review-#{episode_id}",
      "patch_bytes" => byte_size(patch),
      "patch_digest" => digest(patch),
      "patch_truncated" => false,
      "policy_digest" => @digest,
      "policy_findings" => [],
      "publishable" => true,
      "rebase" => "clean",
      "session_id" => session_id,
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end

  defp digest(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp digest(value), do: Responder.CanonicalJSON.digest(value)
end
