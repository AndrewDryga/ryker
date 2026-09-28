defmodule Ryker.Publication.DispatcherTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]

  import Ecto.Query

  alias Ryker.ControlPlane.FailureProjection
  alias Ryker.Delivery.Adapters
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Publication.Custody, as: PublicationCustody
  alias Ryker.Publication.{Dispatcher, Publication}
  alias Ryker.Records
  alias Ryker.Work.{Custody, DeliveryReceipt, Result, Session, Submission}

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule Coop do
    # Every read of the session is a worker command in production; the count
    # is what a publication that can never succeed used to spend forever.
    def get_session({agent, _effects}, _session_id) do
      Agent.get_and_update(agent, fn state ->
        state = Map.update(state, :session_calls, 1, &(&1 + 1))

        case Map.get(state, :session_errors, []) do
          [reason | remaining] -> {{:error, reason}, %{state | session_errors: remaining}}
          [] -> {{:ok, state.session}, state}
        end
      end)
    end

    def run_review({agent, _effects}, _session_id, key, expected_revision) do
      # What a person does while Coop is still checking happens inside the
      # call, where their click lands in production.
      case Agent.get(agent, &Map.get(&1, :during_review)) do
        nil -> :ok
        act -> act.()
      end

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

    def publish_review({_coop, agent}, session_id, review_key, review_id, key, body) do
      Agent.get_and_update(agent, fn state ->
        receipt = %{
          "branch_ref" => "refs/heads/" <> body["branch"],
          "candidate_tree" => body["candidate_tree"],
          "commit_sha" => body["candidate_head"],
          "pull_request_number" => 91,
          "pull_request_url" => "https://github.com/acme/ryker/pull/91",
          "repository" => "ryker"
        }

        call = {session_id, review_key, review_id, key, body}
        next = %{state | publication_requests: state.publication_requests ++ [call]}

        case Map.get(state, :publication_errors, []) do
          [reason | remaining] ->
            {{:error, reason}, Map.put(next, :publication_errors, remaining)}

          [] ->
            {publication_result(state, receipt), next}
        end
      end)
    end

    defp publication_result(state, receipt) do
      case Map.get(state, :publication_conflict) do
        nil ->
          {:ok, receipt}

        conflict ->
          {:error, {:publication_conflict, :publication_branch_already_exists, conflict}}
      end
    end
  end

  defmodule DeliveryPublisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher

    alias Ryker.Work.DeliveryReceipt

    def transport, do: "slack"

    def publish_message(request, agent) do
      Agent.get_and_update(agent, fn state ->
        index = length(state.delivery_requests) + 1
        errors = Map.get(state, :delivery_errors, %{})
        {reason, remaining} = Map.pop(errors, request.ref)

        result =
          case reason do
            nil ->
              DeliveryReceipt.new(
                request.ref,
                request.transport,
                request.conversation_ref,
                request.thread_ref,
                "message:publication:#{index}"
              )

            failure ->
              {:error, failure}
          end

        next = %{state | delivery_requests: state.delivery_requests ++ [request]}
        {result, Map.put(next, :delivery_errors, remaining)}
      end)
    end
  end

  defmodule ReactionPublisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.ReactionPublisher

    def transport, do: "slack"
    def publish_reaction(_request, _binding), do: {:error, :not_used}
  end

  test "one delivered offer is reviewed, approved, and published as the exact draft" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} = delivered_offer!("runtime")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    review = review_document(work_claim)

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          review: review,
          review_calls: [],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "job_ref" => work_claim.session.external_ref,
            "job_digest" => work_claim.session.worker_job_digest,
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
    assert key == "ryker:publication:review:#{publication.id}:g1"

    effects = Agent.get(effects, & &1)
    assert [review_delivery, published_delivery] = effects.delivery_requests

    assert review_delivery.document["records"] |> hd() |> Map.fetch!("kind") ==
             "publication_review"

    assert published_delivery.document["records"] |> hd() |> Map.fetch!("kind") ==
             "publication_result"

    assert [{session_id, ^key, review_id, publish_key, body}] = effects.publication_requests
    assert session_id == work_claim.session.coop_session_id
    assert review_id == review["operation_id"]
    assert publish_key == "ryker:publication:publish:#{publication.id}:g1"
    assert body["candidate_head"] == review["candidate_head"]
    assert body["candidate_tree"] == review["candidate_tree"]
    assert body["authorization_ref"] == "interaction:publish:runtime"
    assert body["expected_head"] == ""
    assert body["pull_request_number"] == 0
    refute Map.has_key?(body, "patch")
  end

  # The result card is painted after the draft exists, so a Slack failure there
  # returns a publication that already owns pull request 91 to the queue. The
  # retry has to be the repaint and nothing else: a second publish would give
  # one approval two drafts and orphan the first behind a card that never
  # repainted. Nothing exercised this retry — the catalog claimed the state and
  # no test drove it, which is how the 2026-09-12 audit found a "parked state
  # clears native activity" claim that was false and had been re-sending "is
  # working..." to a thread every 90 seconds forever.
  test "a failed result repaint retries onto the same pull request and never opens a second draft" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} = delivered_offer!("repaint")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    review = review_document(work_claim)
    result_ref = "publication-result:#{publication.id}:g1"

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          review: review,
          review_calls: [],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "job_ref" => work_claim.session.external_ref,
            "job_digest" => work_claim.session.worker_job_digest,
            "revision" => 7,
            "state" => "exhausted"
          }
        }
      end)

    {:ok, effects} =
      Agent.start_link(fn ->
        %{
          delivery_errors: %{result_ref => {:slack_api_error, "ratelimited"}},
          delivery_requests: [],
          publication_id: publication.id,
          publication_requests: []
        }
      end)

    options = dispatcher_options(coop, effects)

    assert {:ok, {:executed, %{phase: :reviewed}}} = Dispatcher.run_once(options)
    assert {:ok, {:executed, %{phase: :delivered}}} = Dispatcher.run_once(options)
    reviewed = Repo.get!(Publication, publication.id)

    assert {:ok, %{status: :approved}} =
             PublicationCustody.approve(%{
               actor_ref: "slack:user:U-operator",
               approval_ref: "interaction:publish:repaint",
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
    opened = Repo.get!(Publication, publication.id)
    assert opened.status == :published_ready
    assert opened.pull_request_number == 91

    assert {:ok, {:deferred, {:slack_api_error, "ratelimited"}}} = Dispatcher.run_once(options)

    deferred = Repo.get!(Publication, publication.id)
    assert deferred.status == :published_ready
    assert deferred.last_error_code == "slack_api_error"
    assert deferred.lease_ref == nil
    assert deferred.pull_request_number == 91
    assert deferred.pull_request_url == "https://github.com/acme/ryker/pull/91"
    assert deferred.publication_receipt == opened.publication_receipt

    Repo.update_all(
      from(saved in Publication, where: saved.id == ^publication.id),
      set: [next_attempt_at: @now]
    )

    assert {:ok, {:executed, %{phase: :delivered}}} = Dispatcher.run_once(options)

    published = Repo.get!(Publication, publication.id)
    assert published.status == :published
    assert published.pull_request_number == 91
    assert published.pull_request_url == "https://github.com/acme/ryker/pull/91"
    assert published.publication_receipt == opened.publication_receipt

    state = Agent.get(effects, & &1)

    # One approval, one create: the publisher was never asked a second time.
    assert [_only] = state.publication_requests

    # The retry addresses the exact delivery ref the failed attempt used, which
    # is the ref Slack reconciles onto the message already holding it.
    assert [_review, failed, retried] = state.delivery_requests
    assert failed.ref == result_ref
    assert retried.ref == result_ref
  end

  test "readiness completes without publication credentials but cannot publish a draft" do
    # Missing GitHub setup stalled an already-authorized readiness request at
    # zero attempts. Checks must finish without turning that into write authority.
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} =
      delivered_offer!("review-without-github")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          review: review_document(work_claim),
          review_calls: [],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "job_ref" => work_claim.session.external_ref,
            "job_digest" => work_claim.session.worker_job_digest,
            "revision" => 7,
            "state" => "exhausted"
          }
        }
      end)

    {:ok, effects} = Agent.start_link(fn -> %{delivery_requests: []} end)

    options =
      dispatcher_options(coop, effects)
      |> Keyword.update!(:executor_options, fn options ->
        Keyword.put(options, :repositories, %{})
      end)

    assert {:ok, {:executed, %{phase: :reviewed}}} = Dispatcher.run_once(options)
    assert {:ok, {:executed, %{phase: :delivered}}} = Dispatcher.run_once(options)
    reviewed = Repo.get!(Publication, publication.id)
    assert reviewed.status == :reviewed
    assert reviewed.review_document["candidate_retained"]
    assert length(Agent.get(coop, & &1.review_calls)) == 1
    assert length(Agent.get(effects, & &1.delivery_requests)) == 1

    assert {:ok, %{status: :approved}} =
             PublicationCustody.approve(%{
               actor_ref: "slack:user:U-operator",
               approval_ref: "interaction:publish:without-github",
               occurred_at: DateTime.add(@now, 2, :second),
               publication_ref: publication.ref,
               target: %{
                 conversation_ref: work_claim.episode.destination_conversation_ref,
                 message_ref: reviewed.review_delivery_receipt["message_ref"],
                 thread_ref: work_claim.episode.destination_thread_ref,
                 transport: "slack"
               }
             })

    assert {:ok, {:deferred, {:publication_repository_not_configured, "ryker"}}} =
             Dispatcher.run_once(options)

    deferred = Repo.get!(Publication, publication.id)
    assert deferred.status == :publish_pending
    assert deferred.review_document["candidate_retained"]
    assert deferred.publication_receipt == nil
    assert deferred.last_error_code == "publication_repository_not_configured"
  end

  test "a crossed Coop review identity is deferred without storing review evidence" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} = delivered_offer!("crossed")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    review = %{review_document(work_claim) | "session_id" => "someone-else"}

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          review: review,
          review_calls: [],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "job_ref" => work_claim.session.external_ref,
            "job_digest" => work_claim.session.worker_job_digest,
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

  test "a first-publication branch race preserves exact recovery identity before deferral" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} =
      delivered_offer!("first-publication-race")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    review = review_document(work_claim)
    candidate_sha = review["candidate_head"]
    observed_sha = String.duplicate("8", 40)
    branch_ref = "refs/heads/ryker/#{publication.id}"

    conflict = %{
      "branch_ref" => branch_ref,
      "candidate_commit_sha" => candidate_sha,
      "github_repository" => "acme/ryker",
      "observed_head_sha" => observed_sha,
      "pull_request_number" => 91,
      "pull_request_url" => "https://github.com/acme/ryker/pull/91",
      "repository" => "ryker"
    }

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          review: review,
          review_calls: [],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "job_ref" => work_claim.session.external_ref,
            "job_digest" => work_claim.session.worker_job_digest,
            "revision" => 7,
            "state" => "exhausted"
          }
        }
      end)

    {:ok, effects} =
      Agent.start_link(fn ->
        %{
          delivery_requests: [],
          publication_conflict: conflict,
          publication_id: publication.id,
          publication_requests: []
        }
      end)

    options = dispatcher_options(coop, effects)
    assert {:ok, {:executed, %{phase: :reviewed}}} = Dispatcher.run_once(options)
    assert {:ok, {:executed, %{phase: :delivered}}} = Dispatcher.run_once(options)
    reviewed = Repo.get!(Publication, publication.id)

    assert {:ok, %{status: :approved}} =
             PublicationCustody.approve(%{
               actor_ref: "slack:user:U-operator",
               approval_ref: "interaction:publish:first-publication-race",
               occurred_at: DateTime.add(@now, 2, :second),
               publication_ref: publication.ref,
               target: %{
                 conversation_ref: work_claim.episode.destination_conversation_ref,
                 message_ref: reviewed.review_delivery_receipt["message_ref"],
                 thread_ref: work_claim.episode.destination_thread_ref,
                 transport: "slack"
               }
             })

    assert {:ok,
            {:deferred, {:publication_conflict, :publication_branch_already_exists, ^conflict}}} =
             Dispatcher.run_once(options)

    stored = Repo.get!(Publication, publication.id)
    assert stored.status == :publish_pending
    assert stored.last_error_code == "publication_branch_already_exists"
    assert stored.branch_ref == branch_ref
    assert stored.commit_sha == candidate_sha
    assert stored.expected_remote_head_sha == observed_sha
    assert stored.github_repository == "acme/ryker"
    assert stored.pull_request_number == 91
    assert stored.pull_request_url == conflict["pull_request_url"]
    assert stored.publication_receipt == nil
    assert stored.lease_ref == nil
    assert [_request] = Agent.get(effects, & &1.publication_requests)

    Repo.update_all(
      from(saved in Publication, where: saved.id == ^publication.id),
      set: [next_attempt_at: @now]
    )

    assert {:ok, :idle} = Dispatcher.run_once(options)
    assert [_request] = Agent.get(effects, & &1.publication_requests)
  end

  test "a confirmed revision conflict spends only the review operation generation" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} =
      delivered_offer!("review-revision")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    review = review_document(work_claim)

    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          review: %{review | "session_revision" => 8},
          review_calls: [],
          review_errors: [{:coop_error, 409, "revision_conflict", "expected 7, current 8"}],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "job_ref" => work_claim.session.external_ref,
            "job_digest" => work_claim.session.worker_job_digest,
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

    key1 = "ryker:publication:review:#{publication.id}:g1"
    key2 = "ryker:publication:review:#{publication.id}:g2"
    assert [{^key1, 7}, {^key2, 8}] = Agent.get(coop, & &1.review_calls)
  end

  # Production, 2026-09-10: a person pressed Review on a change whose worker
  # session Ryker had closed five hours earlier. Every attempt asked the worker
  # for the session, read `closed`, called it a protocol error and waited a
  # minute: 2,902 worker commands over two days, each holding one of the two
  # publishing slots, while the Failures page said a retry would not help and
  # offered nothing that could end it.
  test "a publication whose worker session closed ends by itself and says why" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} =
      delivered_offer!("closed-session")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    coop = review_coop!(work_claim, "closed")
    effects = effects!(publication)
    options = dispatcher_options(coop, effects)

    assert {:ok, {:discarded, {:publication_review_session_closed, "closed"}}} =
             Dispatcher.run_once(options)

    ended = Repo.get!(Publication, publication.id)
    assert ended.status == :discarded
    assert ended.discarded_reason == :review_session_closed
    assert ended.last_error_code == nil
    assert ended.next_attempt_at == nil
    assert ended.lease_ref == nil
    assert ended.recovery_generation == publication.recovery_generation + 1
    # The request and its one attempt stay as history.
    assert ended.review_request_ref == publication.review_request_ref
    assert ended.attempt_count == 1

    # Nothing is left to retry, so nothing asks the worker again.
    assert {:ok, :idle} = Dispatcher.run_once(options)
    assert Agent.get(coop, & &1.session_calls) == 1
    assert Agent.get(coop, & &1.review_calls) == []
    assert Agent.get(effects, & &1.delivery_requests) == []
    assert FailureProjection.fetch("publication", publication.ref) == :not_found
  end

  # Ryker records the close itself when it cleans a session up, so asking the
  # worker about it again only spends a command to learn what is on disk here.
  test "a publication whose session Ryker already closed ends without asking the worker" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} =
      delivered_offer!("host-closed-session")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    Repo.update_all(
      from(session in Session, where: session.id == ^work_claim.session.id),
      set: [closed_at: @now]
    )

    coop = review_coop!(work_claim, "closed")
    options = dispatcher_options(coop, effects!(publication))

    assert {:ok, {:discarded, {:publication_review_session_closed, "closed"}}} =
             Dispatcher.run_once(options)

    assert Repo.get!(Publication, publication.id).discarded_reason == :review_session_closed
    assert Agent.get(coop, & &1.session_calls) == 0
  end

  # A failed attempt wrote last_error_code and nothing cleared it: the review
  # that then succeeded carried the old code into every later phase, so a
  # change moving along normally stayed on the Failures page as broken.
  test "a publication that recovered by itself is not listed as failing" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} =
      delivered_offer!("recovered")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    coop = review_coop!(work_claim, "open", session_errors: [{:coop_unavailable, :simulated}])
    options = dispatcher_options(coop, effects!(publication))

    assert {:ok, {:deferred, {:coop_unavailable, :simulated}}} = Dispatcher.run_once(options)

    assert {:ok, %{summary: "coop_unavailable"}} =
             FailureProjection.fetch("publication", publication.ref)

    Repo.update_all(
      from(saved in Publication, where: saved.id == ^publication.id),
      set: [next_attempt_at: @now]
    )

    assert {:ok, {:executed, %{phase: :reviewed}}} = Dispatcher.run_once(options)
    reviewed = Repo.get!(Publication, publication.id)
    assert reviewed.status == :review_ready
    assert reviewed.last_error_code == nil
    assert FailureProjection.fetch("publication", publication.ref) == :not_found

    assert {:ok, {:executed, %{phase: :delivered}}} = Dispatcher.run_once(options)
    waiting = Repo.get!(Publication, publication.id)
    assert waiting.status == :reviewed
    assert waiting.last_error_code == nil
    assert FailureProjection.fetch("publication", publication.ref) == :not_found
  end

  # A person may discard a change while Coop still checks it (Andrew,
  # 2026-09-28). The running review then loses its lease: its answer must
  # change nothing, and ending that way is no dispatcher failure, which the
  # worker would log as an error for every discard.
  test "a change discarded while its review runs stays discarded and the review ends quietly" do
    %{claim: work_claim, offer: offer, offer_receipt: offer_receipt} =
      delivered_offer!("discarded-mid-review")

    assert {:ok, %{publication: publication}} =
             PublicationCustody.request_review(review_request(work_claim, offer, offer_receipt))

    owner = self()

    discard = fn ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())

      send(
        owner,
        {:discarded_mid_review, PublicationCustody.recover(publication.ref, :discard, 1)}
      )
    end

    coop = review_coop!(work_claim, "open", during_review: discard)
    effects = effects!(publication)
    options = dispatcher_options(coop, effects)
    result = Dispatcher.run_once(options)

    assert_received {:discarded_mid_review, {:ok, %{publication: %{status: :discarded}}}}
    assert {:ok, {:lease_lost, :publication_lease_lost}} = result

    ended = Repo.get!(Publication, publication.id)
    assert ended.status == :discarded
    assert ended.review_document == nil
    assert ended.last_error_code == nil
    assert ended.next_attempt_at == nil
    assert Agent.get(effects, & &1.delivery_requests) == []
    assert {:ok, :idle} = Dispatcher.run_once(options)
  end

  defp review_coop!(work_claim, state, options \\ []) do
    {:ok, coop} =
      Agent.start_link(fn ->
        %{
          review: review_document(work_claim),
          review_calls: [],
          session: %{
            "external_ref" => work_claim.session.external_ref,
            "id" => work_claim.session.coop_session_id,
            "job_ref" => work_claim.session.external_ref,
            "job_digest" => work_claim.session.worker_job_digest,
            "revision" => 7,
            "state" => state
          },
          session_calls: 0,
          session_errors: Keyword.get(options, :session_errors, []),
          during_review: Keyword.get(options, :during_review)
        }
      end)

    coop
  end

  defp effects!(publication) do
    {:ok, effects} =
      Agent.start_link(fn ->
        %{delivery_requests: [], publication_id: publication.id, publication_requests: []}
      end)

    effects
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
        client: {coop, effects},
        repositories: %{"ryker" => %{base_branch: "main", branch_prefix: "ryker"}}
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
               "stage" => "implementation",
               "writable_repository" => "ryker"
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
                   conversation_ref: "slack:TPUBLICATIONDISPATCH:C456",
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
    WorkerJob.pin!(claim.session)

    assert {:ok, submission} =
             Submission.new(
               %{"input" => claim.episode.key},
               "Implement the frozen request.",
               %{"type" => "object"},
               "work-final-live-v3"
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
      "candidate_retained" => true,
      "patch_truncated" => false,
      "job_digest" => claim.session.worker_job_digest,
      "policy_findings" => [],
      "publishable" => true,
      "rebase" => "clean",
      "session_id" => claim.session.coop_session_id,
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end
end
