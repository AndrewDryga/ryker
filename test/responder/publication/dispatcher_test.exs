defmodule Responder.Publication.DispatcherTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Delivery.Adapters
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.Publication.{Dispatcher, Publication}
  alias Responder.State.Records
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule Coop do
    def get_session(agent, _session_id), do: {:ok, Agent.get(agent, & &1.session)}

    def run_review(agent, _session_id, key, expected_revision) do
      Agent.get_and_update(agent, fn state ->
        response = %{
          "operation" => %{
            "id" => state.review["operation_id"],
            "method" => "RunReview",
            "resource_id" => state.review["session_id"],
            "resource_type" => "review",
            "state" => "succeeded"
          },
          "review" => state.review
        }

        next = %{state | review_calls: state.review_calls ++ [{key, expected_revision}]}

        case Map.get(state, :review_errors, []) do
          [reason | remaining] ->
            session = Map.update!(state.session, "revision", &(&1 + 1))
            {{:error, reason}, %{next | review_errors: remaining, session: session}}

          [] ->
            {{:ok, response}, next}
        end
      end)
    end

    def get_review_patch(agent, artifact_id, digest, bytes) do
      Agent.get_and_update(agent, fn state ->
        call = {artifact_id, digest, bytes}
        {{:ok, state.patch}, %{state | patch_calls: state.patch_calls ++ [call]}}
      end)
    end
  end

  defmodule DeliveryPublisher do
    @behaviour Responder.Delivery.Platform
    @behaviour Responder.Delivery.MessagePublisher

    alias Responder.Work.DeliveryReceipt

    def transport, do: "slack"

    def publish_message(request, agent) do
      Agent.get_and_update(agent, fn state ->
        index = length(state.delivery_requests) + 1

        {:ok, receipt} =
          DeliveryReceipt.new(
            request.ref,
            request.transport,
            request.conversation_ref,
            request.thread_ref,
            "message:publication:#{index}"
          )

        {{:ok, receipt}, %{state | delivery_requests: state.delivery_requests ++ [request]}}
      end)
    end
  end

  defmodule ReactionPublisher do
    @behaviour Responder.Delivery.Platform
    @behaviour Responder.Delivery.ReactionPublisher

    def transport, do: "slack"
    def publish_reaction(_request, _binding), do: {:error, :not_used}
  end

  defmodule DraftPublisher do
    @behaviour Responder.Publication.Publisher

    def publish(request, agent) do
      Agent.get_and_update(agent, fn state ->
        receipt = %{
          "branch_ref" => "refs/heads/responder/#{state.publication_id}",
          "candidate_tree" => request.review["candidate_tree"],
          "commit_sha" => String.duplicate("9", 40),
          "pull_request_number" => 91,
          "pull_request_url" => "https://github.com/acme/responder/pull/91",
          "repository" => request.repository
        }

        {{:ok, receipt}, %{state | publication_requests: state.publication_requests ++ [request]}}
      end)
    end
  end

  test "one delivered offer is reviewed, approved, and published as the exact draft" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} = delivered_offer!("runtime")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    patch = "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"
    review = review_document(work_claim, patch)

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          patch: patch,
          patch_calls: [],
          review: review,
          review_calls: [],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "policy" => work_claim.session.policy,
            "policy_digest" => work_claim.session.policy_digest,
            "revision" => 7,
            "state" => "exhausted"
          }
        }
      end)

    {:ok, effects} =
      Agent.start_link(fn ->
        %{delivery_requests: [], publication_id: publication.id, publication_requests: []}
      end)

    options = dispatcher_options(coop, effects)

    assert {:ok, {:executed, %{phase: :reviewed}}} = Dispatcher.run_once(options)
    assert Repo.get!(Publication, publication.id).status == :review_ready

    assert {:ok, {:executed, %{phase: :delivered}}} = Dispatcher.run_once(options)
    reviewed = Repo.get!(Publication, publication.id)
    assert reviewed.status == :reviewed

    assert {:ok, %{status: :approved}} =
             PublicationCustody.approve(%{
               actor_ref: "slack:user:U-operator",
               approval_ref: "interaction:publish:runtime",
               occurred_at: DateTime.add(@now, 2, :second),
               publication_ref: publication.ref,
               target: %{
                 conversation_ref: work_claim.episode.destination_conversation_ref,
                 message_ref: reviewed.review_delivery_receipt["message_ref"],
                 thread_ref: work_claim.episode.destination_thread_ref,
                 transport: "slack"
               }
             })

    assert {:ok, {:executed, %{phase: :published}}} = Dispatcher.run_once(options)
    assert Repo.get!(Publication, publication.id).status == :published_ready

    assert {:ok, {:executed, %{phase: :delivered}}} = Dispatcher.run_once(options)
    published = Repo.get!(Publication, publication.id)
    assert published.status == :published
    assert published.publication_receipt["candidate_tree"] == review["candidate_tree"]

    state = Agent.get(coop, & &1)
    assert [{key, 7}] = state.review_calls
    assert key == "responder:publication:review:#{publication.id}:g1"

    artifact_id = review["patch_artifact_id"]
    patch_digest = review["patch_digest"]
    patch_bytes = byte_size(patch)
    assert [{^artifact_id, ^patch_digest, ^patch_bytes}] = state.patch_calls

    effects = Agent.get(effects, & &1)
    assert [review_delivery, published_delivery] = effects.delivery_requests

    assert review_delivery.document["records"] |> hd() |> Map.fetch!("kind") ==
             "publication_review"

    assert published_delivery.document["records"] |> hd() |> Map.fetch!("kind") ==
             "publication_result"

    assert [request] = effects.publication_requests
    assert request.patch == patch
    assert request.review == review
    assert request.approval_ref == "interaction:publish:runtime"
  end

  test "a crossed Coop review identity is deferred without storing review evidence" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} = delivered_offer!("crossed")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    patch = "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"
    review = %{review_document(work_claim, patch) | "session_id" => "someone-else"}

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          patch: patch,
          patch_calls: [],
          review: review,
          review_calls: [],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "policy" => work_claim.session.policy,
            "policy_digest" => work_claim.session.policy_digest,
            "revision" => 7,
            "state" => "open"
          }
        }
      end)

    {:ok, effects} =
      Agent.start_link(fn ->
        %{delivery_requests: [], publication_id: publication.id, publication_requests: []}
      end)

    assert {:ok, {:deferred, {:publication_coop_protocol_error, :review}}} =
             Dispatcher.run_once(dispatcher_options(coop, effects))

    stored = Repo.get!(Publication, publication.id)
    assert stored.status == :review_pending
    assert stored.review_document == nil
    assert stored.lease_ref == nil
    assert stored.next_attempt_at != nil
  end

  test "a confirmed revision conflict spends only the review operation generation" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} =
      delivered_offer!("review-revision")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    patch = "diff --git a/lib/fix.ex b/lib/fix.ex\n+fixed\n"
    review = review_document(work_claim, patch)

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          patch: patch,
          patch_calls: [],
          review: %{review | "session_revision" => 8},
          review_calls: [],
          review_errors: [{:coop_error, 409, "revision_conflict", "expected 7, current 8"}],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "policy" => work_claim.session.policy,
            "policy_digest" => work_claim.session.policy_digest,
            "revision" => 7,
            "state" => "open"
          }
        }
      end)

    {:ok, effects} =
      Agent.start_link(fn ->
        %{delivery_requests: [], publication_id: publication.id, publication_requests: []}
      end)

    options = dispatcher_options(coop, effects)

    assert {:ok,
            {:deferred,
             {:publication_review_generation_spent,
              {:coop_error, 409, "revision_conflict", _detail}}}} = Dispatcher.run_once(options)

    deferred = Repo.get!(Publication, publication.id)
    assert deferred.review_generation == 2
    assert deferred.review_expected_revision == nil

    Repo.update_all(
      from(saved in Publication, where: saved.id == ^publication.id),
      set: [next_attempt_at: @now]
    )

    assert {:ok, {:executed, %{phase: :reviewed}}} = Dispatcher.run_once(options)

    key1 = "responder:publication:review:#{publication.id}:g1"
    key2 = "responder:publication:review:#{publication.id}:g2"
    assert [{^key1, 7}, {^key2, 8}] = Agent.get(coop, & &1.review_calls)
  end

  defp dispatcher_options(coop, effects) do
    {:ok, adapters} =
      Adapters.new(%{
        "slack" => %{
          binding: effects,
          message_publisher: DeliveryPublisher,
          reaction_publisher: ReactionPublisher
        }
      })

    [
      executor_options: [
        adapters: adapters,
        api: Coop,
        client: coop,
        publisher: DraftPublisher,
        publisher_binding: effects
      ],
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "publication:test"
    ]
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

  defp review_document(claim, patch) do
    operation_id = "op-review-#{claim.episode.id}"

    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => operation_id,
      "parent_head" => String.duplicate("4", 40),
      "parent_tree" => String.duplicate("5", 40),
      "patch_artifact_id" => operation_id,
      "patch_bytes" => byte_size(patch),
      "patch_digest" => digest(patch),
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
