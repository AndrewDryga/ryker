defmodule Ryker.ControlPlane.PublicationLabTest do
  use Ryker.DataCase, async: true

  alias Ryker.ControlPlane.{Actions, Projection, Publisher}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Publication.{Changeset, Publication}
  alias Ryker.Publication.Custody, as: PublicationCustody
  alias Ryker.Repo
  alias Ryker.Slack.TaskCardProjection
  alias Ryker.State.{Record, Records}

  alias Ryker.Work.{Cancellation, Custody, DeliveryReceipt, Result, SubmissionBuilder}

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
    assert requested.publication.repository == "ryker"
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

  test "a confirmed task with no prepared changes does not create a readiness review" do
    task_offer = delivered_task_offer!()

    actions =
      Actions.callbacks(profile(), %{
        "ryker" => %{name: "ryker-contributor", digest: @digest}
      })

    assert {:ok, confirmation} =
             actions.act_on_lab_record.(@conversation_id, task_offer.ref, :confirm_task, nil)

    assert {:ok, child_claim} = Custody.claim_next("lab-task-no-changes", 60, :work)
    child_claim = bind_claim!(child_claim, "task-no-changes")

    settle_claim!(
      child_claim,
      %{
        "message" => "No repository change is needed.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      },
      "control-plane-message:task-no-changes"
    )

    refute Repo.get_by(Publication, episode_id: confirmation.episode.id)
  end

  test "a confirmed Lab task starts its checks without another readiness control" do
    task_offer = delivered_task_offer!()

    actions =
      Actions.callbacks(profile(), %{
        "ryker" => %{name: "ryker-contributor", digest: @digest}
      })

    assert {:ok, confirmation} =
             actions.act_on_lab_record.(@conversation_id, task_offer.ref, :confirm_task, nil)

    assert {:ok, child_claim} = Custody.claim_next("lab-task-readiness", 60, :work)
    assert child_claim.episode.id == confirmation.episode.id
    child_claim = bind_claim!(child_claim, "task-readiness")

    assert {:ok, older_publication_offer} =
             Records.create(
               Records.token(child_claim.turn),
               "publication-race-candidate",
               "publication_offer",
               %{
                 "body" =>
                   "Keep this second exact candidate available for the control-race test.",
                 "title" => "Older independent publication candidate"
               }
             )

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

    # A retained milestone must not start a review while the task is waiting
    # for input. Only its completed result may enter automatic review custody.
    session = Repo.get!(Ryker.Work.Session, child_claim.session.id)
    waiting_turn = %{child_claim.turn | continuation: %{"kind" => "wait"}}

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               PublicationCustody.ensure_task_review_in_transaction(
                 confirmation.episode,
                 session,
                 waiting_turn
               )
             end)

    refute Repo.get_by(Publication, record_id: publication_offer.id)

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

    assert task_card.status == "reviewing"
    refute :request_task_readiness in task_card.actions
    readiness = %{publication: Repo.get_by!(Publication, record_id: publication_offer.id)}
    assert readiness.publication.status == :review_pending
    assert readiness.publication.review_requested_by_actor_ref == "control-plane:local"
    assert is_nil(readiness.publication.approval_ref)
    assert readiness.publication.record_id == publication_offer.id
    assert readiness.publication.episode_id == confirmation.episode.id
    assert readiness.publication.destination_transport == "control_plane"
    assert readiness.publication.destination_conversation_ref == conversation_ref()

    # The real retained runner task has prepared changes but predates automatic
    # review custody. Removing a button must not relabel that work Completed.
    Repo.delete!(readiness.publication)
    confirmed_task = Repo.get!(Record, task_offer.id)
    assert {:ok, stranded} = TaskCardProjection.build(confirmed_task)
    assert stranded.document["task_card"]["status"] == "action_required"
    assert stranded.document["task_card"]["action_needed"] =~ "checks have not started"
    assert is_nil(stranded.document["task_card"]["publication"])
    Repo.insert!(Ecto.put_meta(readiness.publication, state: :built))

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

    # The person who confirmed this task named the repository and the scope, so
    # the exact candidate their work produced opens as a draft on that same
    # grant. The operator-owned approval path stays proved on a standalone
    # publication offer, which carries no task grant, in the first test here.
    assert {:ok, %Publication{status: :publish_pending} = authorized} =
             PublicationCustody.confirm_delivery(
               readiness.publication.ref,
               review_delivery_claim.lease_ref,
               review_receipt
             )

    assert authorized.approval_ref == "host:publication:draft:#{authorized.id}"
    assert authorized.approved_by_actor_ref == "control-plane:local"

    assert {:ok, reviewed_conversation} = Projection.lab_conversation(@conversation_id)

    reviewed_task =
      reviewed_conversation.messages
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.ref == task_offer.ref))

    refute :approve_task_publication in reviewed_task.actions
    assert reviewed_task.recovery_generation == 1
    assert reviewed_task.publication_ref == readiness.publication.ref

    newer_publication =
      %{
        body: older_publication_offer.payload["body"],
        destination_conversation_ref: conversation_ref(),
        destination_thread_ref: conversation_ref(),
        destination_transport: "control_plane",
        episode_id: confirmation.episode.id,
        id: Ecto.UUID.generate(),
        offer_message_ref: "control-plane-message:task-readiness",
        record_id: older_publication_offer.id,
        ref: "publication:lab-control-race:#{older_publication_offer.id}",
        repository: "ryker",
        review_request_ref: "control-plane-action:newer-publication",
        review_requested_at: DateTime.add(@now, 3, :second),
        review_requested_by_actor_ref: "control-plane:operator",
        session_id: readiness.publication.session_id,
        status: :review_pending,
        title: older_publication_offer.payload["title"]
      }
      |> Changeset.insert()
      |> Repo.insert!()

    assert newer_publication.ref != readiness.publication.ref
    assert newer_publication.recovery_generation == reviewed_task.recovery_generation

    # A recovery control carried over from the pre-autonomous card cannot
    # re-open a draft the host already committed to, and it must never resolve
    # onto the newer publication that shares its generation.
    assert actions.act_on_lab_record.(
             @conversation_id,
             task_offer.ref,
             :update_task_publication,
             %{
               generation: reviewed_task.recovery_generation,
               publication_ref: reviewed_task.publication_ref
             }
           ) == {:error, :publication_recovery_not_allowed}

    assert Repo.get!(Publication, newer_publication.id).status == :review_pending
    assert Repo.get!(Publication, readiness.publication.id).status == :publish_pending
    Repo.delete!(newer_publication)

    assert {:ok, publish_claim} = PublicationCustody.claim_next("lab-task-publish", 60)

    publication_receipt = %{
      "branch_ref" => "refs/heads/ryker/lab-parity",
      "candidate_tree" => review["candidate_tree"],
      "commit_sha" => String.duplicate("c", 40),
      "pull_request_number" => 42,
      "pull_request_url" => "https://github.com/example/ryker/pull/42",
      "repository" => "ryker"
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
    assert published_task.url == "https://github.com/example/ryker/pull/42"

    assert {:ok, check} =
             actions.act_on_lab_record.(
               @conversation_id,
               task_offer.ref,
               :check_task_publication,
               %{publication_ref: readiness.publication.ref}
             )

    assert check.status == :requested

    # A previously reviewed/published task must not hide a failed correction
    # behind its older publication status. This follows real episode custody.
    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref(),
                   thread_ref: conversation_ref(),
                   transport: "control_plane"
                 },
                 episode_id: confirmation.episode.id,
                 episode_key: confirmation.episode.key,
                 native_input_id: "lab:blocked-correction",
                 linked_episode_id: confirmation.episode.linked_episode_id,
                 occurred_at: DateTime.utc_now(),
                 payload: %{"text" => "Please include the follow-up correction."},
                 turn_ref: "lab:blocked-correction"
               })
             )

    assert {:ok, followup} = Custody.claim_next("lab:followup", 60, :work)

    assert {:ok, _} =
             Custody.request_block(
               followup.episode.id,
               followup.episode.key,
               followup.turn.turn_ref,
               followup.lease_ref,
               "The follow-up could not finish."
             )

    assert {:ok, cancellation} = Custody.claim_next("lab:stop-followup", 60, :work)

    assert {:ok, stopped} =
             Cancellation.absent_receipt(
               "ryker:work:create:#{followup.session.id}:g#{followup.session.create_generation}",
               nil,
               followup.session.coop_session_id,
               "closed",
               "ryker:work:cancel-close:#{followup.turn.id}:g1"
             )

    assert {:ok, _} =
             Custody.settle_cancellation(
               followup.episode.id,
               followup.episode.key,
               followup.turn.turn_ref,
               cancellation.lease_ref,
               stopped
             )

    assert {:ok, blocked} = TaskCardProjection.build(confirmed_task)
    assert blocked.document["task_card"]["status"] == "action_required"
    assert blocked.document["task_card"]["action_needed"] =~ "follow-up could not finish"
    assert blocked.document["task_card"]["publication"]["pull_request_url"] == published_task.url
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
               "repository" => "ryker",
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
                 Ryker.Work.Custody.pin_task_episode_in_transaction(
                   episode_id,
                   "ryker-contributor",
                   @digest,
                   "ryker",
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
             Ryker.Work.Custody.claim_next("lab-publication-work", 60, :work)

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
             Ryker.Work.Custody.freeze_submission(
               episode_id,
               turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, bound_session} =
             Ryker.Work.Custody.bind_session(
               episode_id,
               turn_ref,
               claim.lease_ref,
               session.generation,
               session.create_generation,
               "coop-session:lab-publication"
             )

    assert {:ok, _turn} =
             Ryker.Work.Custody.bind_turn(
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
             Ryker.Work.Custody.stage_candidate(
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
             Ryker.Work.Custody.prepare_validation(
               episode_id,
               turn_ref,
               claim.lease_ref,
               candidate_sha,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Ryker.Work.Custody.accept_result(
               episode_id,
               transition.episode.key,
               turn_ref,
               claim.lease_ref,
               candidate_sha,
               1,
               "validation-receipt:lab-publication"
             )

    assert {:ok, delivery_claim} =
             Ryker.Work.Custody.claim_next("lab-publication-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "control_plane",
               conversation_ref,
               conversation_ref,
               "control-plane-message:lab-publication"
             )

    assert {:ok, _settled} =
             Ryker.Work.Custody.confirm_delivery(
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

  defp digest(value), do: Ryker.CanonicalJSON.digest(value)
end
