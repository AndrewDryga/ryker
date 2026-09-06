defmodule Responder.Fixtures.Publication do
  @moduledoc false

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.State.Records
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]

  def published!(suffix, options \\ []) do
    repository = Keyword.get(options, :repository, "responder")
    github_repository = Keyword.get(options, :github_repository, "acme/responder")
    pull_request_number = Keyword.get(options, :pull_request_number, 91)
    thread_ref = Keyword.get(options, :thread_ref, "thread:#{suffix}")
    # Sandbox transactions hold conversation advisory locks until the test exits.
    # Shared fixture destinations stalled four unrelated suites for 15 seconds;
    # only transport-integration tests should opt into an explicitly shared scope.
    fixture_workspace =
      "TPUBLICATION" <> (suffix |> digest() |> String.slice(0, 12) |> String.upcase())

    conversation_ref = Keyword.get(options, :conversation_ref, "slack:#{fixture_workspace}:C456")

    claim = claim_episode!(suffix, repository, thread_ref, conversation_ref)

    {:ok, _goal} =
      Records.create(Records.token(claim.turn), "goal-#{suffix}", "goal", %{
        "authority" => "repository_write",
        "completion_contract" => "The implementation is committed and reviewed.",
        "id" => "engineering-#{suffix}",
        "kind" => "engineering",
        "requested_outcome" => "Implement #{suffix}",
        "required" => true,
        "writable_repository" => repository
      })

    {:ok, offer} =
      Records.create(Records.token(claim.turn), "publication-#{suffix}", "publication_offer", %{
        "body" => "Implements #{suffix} with focused regression coverage.",
        "title" => "Implement #{suffix}"
      })

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

    {:ok, _turn} =
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

    {:ok, result} = Result.new(:reply, final)

    {:ok, _intent} =
      Custody.prepare_validation(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        candidate_sha256,
        1,
        :accept,
        result
      )

    {:ok, accepted} =
      Custody.accept_result(
        claim.episode.id,
        claim.episode.key,
        claim.turn.turn_ref,
        claim.lease_ref,
        candidate_sha256,
        1,
        "validation:#{claim.turn.id}"
      )

    {:ok, delivery} = Custody.claim_next("delivery:#{suffix}", 60, :delivery)

    {:ok, offer_receipt} =
      DeliveryReceipt.new(
        accepted.turn.delivery_ref,
        "slack",
        claim.episode.destination_conversation_ref,
        claim.episode.destination_thread_ref,
        "message:offer:#{suffix}"
      )

    {:ok, _settled} =
      Custody.confirm_delivery(
        claim.episode.id,
        claim.episode.key,
        claim.turn.turn_ref,
        delivery.lease_ref,
        offer_receipt
      )

    {:ok, %{publication: publication}} =
      PublicationCustody.request_review(%{
        actor_ref: "slack:user:U-operator",
        occurred_at: DateTime.add(@now, 1, :second),
        record_ref: offer.ref,
        request_ref: "interaction:review:#{offer.id}",
        target: %{
          conversation_ref: claim.episode.destination_conversation_ref,
          message_ref: offer_receipt["message_ref"],
          thread_ref: claim.episode.destination_thread_ref,
          transport: "slack"
        }
      })

    {:ok, review_claim} = PublicationCustody.claim_next("publication:review:#{suffix}", 60)

    {:ok, frozen} =
      PublicationCustody.freeze_review_revision(publication.ref, review_claim.lease_ref, 7)

    patch = "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"
    review = review_document(claim, patch)

    {:ok, _reviewed} =
      PublicationCustody.store_review(
        publication.ref,
        review_claim.lease_ref,
        frozen.review_generation,
        review,
        patch
      )

    {:ok, review_delivery_claim} =
      PublicationCustody.claim_next("publication:review-delivery:#{suffix}", 60)

    {:ok, review_delivery} =
      PublicationCustody.delivery_request(review_delivery_claim.publication)

    {:ok, review_receipt} =
      DeliveryReceipt.new(
        review_delivery.ref,
        "slack",
        claim.episode.destination_conversation_ref,
        claim.episode.destination_thread_ref,
        "message:reviewed:#{suffix}"
      )

    {:ok, reviewed} =
      PublicationCustody.confirm_delivery(
        publication.ref,
        review_delivery_claim.lease_ref,
        review_receipt
      )

    {:ok, %{publication: _approved}} =
      PublicationCustody.approve(%{
        actor_ref: "slack:user:U-operator",
        approval_ref: "interaction:publish:#{suffix}",
        occurred_at: DateTime.add(@now, 2, :second),
        publication_ref: publication.ref,
        target: %{
          conversation_ref: claim.episode.destination_conversation_ref,
          message_ref: reviewed.review_delivery_receipt["message_ref"],
          thread_ref: claim.episode.destination_thread_ref,
          transport: "slack"
        }
      })

    {:ok, publish_claim} = PublicationCustody.claim_next("publication:publish:#{suffix}", 60)

    receipt = %{
      "branch_ref" => "refs/heads/responder/#{publication.id}",
      "candidate_tree" => review["candidate_tree"],
      "commit_sha" => String.duplicate("9", 40),
      "pull_request_number" => pull_request_number,
      "pull_request_url" => "https://github.com/#{github_repository}/pull/#{pull_request_number}",
      "repository" => repository
    }

    {:ok, _published_ready} =
      PublicationCustody.store_publication(publication.ref, publish_claim.lease_ref, receipt)

    {:ok, result_claim} =
      PublicationCustody.claim_next("publication:result-delivery:#{suffix}", 60)

    {:ok, result_delivery} = PublicationCustody.delivery_request(result_claim.publication)

    {:ok, result_receipt} =
      DeliveryReceipt.new(
        result_delivery.ref,
        "slack",
        claim.episode.destination_conversation_ref,
        claim.episode.destination_thread_ref,
        "message:published:#{suffix}"
      )

    {:ok, published} =
      PublicationCustody.confirm_delivery(publication.ref, result_claim.lease_ref, result_receipt)

    %{episode: claim.episode, publication: published, receipt: receipt}
  end

  defp claim_episode!(suffix, repository, thread_ref, conversation_ref) do
    id = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: conversation_ref,
            thread_ref: thread_ref,
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

    {:ok, _session} =
      Custody.pin_episode(id, "work-contributor", String.duplicate("a", 64), repository)

    {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    bind_remote!(claim)
  end

  defp bind_remote!(claim) do
    {:ok, submission} =
      Submission.new(
        %{"input" => claim.episode.key},
        "Implement the frozen request.",
        %{"type" => "object"},
        "work-final-v1"
      )

    {:ok, frozen} =
      Custody.freeze_submission(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        submission
      )

    {:ok, session} =
      Custody.bind_session(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "coop-session:#{claim.episode.id}"
      )

    {:ok, turn} =
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

  defp review_document(claim, patch) do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "operation:review:#{claim.turn.id}",
      "parent_head" => String.duplicate("5", 40),
      "parent_tree" => String.duplicate("4", 40),
      "patch_artifact_id" => "review-patch:#{claim.turn.id}",
      "patch_bytes" => byte_size(patch),
      "patch_digest" => digest(patch),
      "patch_truncated" => false,
      "policy_digest" => claim.session.policy_digest,
      "policy_findings" => [],
      "publishable" => true,
      "pull_request" => nil,
      "rebase" => "clean",
      "session_id" => claim.session.coop_session_id,
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
