defmodule Ryker.GitHub.RouterTest do
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.GitHub.{Auth, Binding, Router}
  alias Ryker.Ingress.Inbox
  alias Ryker.Publication.{Followup, Followups, LifecycleEvent}
  alias Ryker.State.{ConversationObservation, KnowledgeSnapshot, LearningSources}
  alias Ryker.Work.{Custody, SubmissionBuilder}

  @secret String.duplicate("s", 32)

  test "authenticates and durably records a GitHub comment through the adapter registry" do
    body = Jason.encode!(payload())

    first = request(body, delivery_ref: "delivery-1", event_name: "issue_comment")
    retry = request(body, delivery_ref: "delivery-1", event_name: "issue_comment")

    assert first.status == 202
    assert retry.status == 202
    assert Jason.decode!(retry.resp_body)["status"] == "duplicate"

    assert {:ok, entry} = Inbox.fetch(Jason.decode!(first.resp_body)["input_ref"])
    assert entry.source_kind == "github"
    assert entry.source_ref == "github-main"

    assert entry.source_capabilities["react"]["emoji_names"] ==
             ~w(+1 -1 confused eyes heart hooray laugh rocket)

    assert entry.destination_conversation_ref == "github:github-main:repository:99"
    assert entry.destination_thread_ref == "github:github-main:pull:42"
    assert entry.work_policy == "github-read-only"
    assert entry.work_policy_digest == String.duplicate("a", 64)
    assert entry.repository_ref == "octo/example"
  end

  test "repository access is checked before a GitHub conversation request is admitted" do
    body = Jason.encode!(payload())

    denied =
      request(body,
        delivery_ref: "delivery-read-only",
        repository_access: fn _binding, _payload -> {:error, :actor_not_authorized} end
      )

    assert denied.status == 200

    assert Jason.decode!(denied.resp_body) == %{
             "reason" => "repository_write_access_required",
             "status" => "ignored"
           }

    unavailable =
      request(body,
        delivery_ref: "delivery-access-unavailable",
        repository_access: fn _binding, _payload ->
          {:error, {:github_repository_access_unavailable, :timeout}}
        end
      )

    assert unavailable.status == 503
    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0
  end

  test "a captured signed body cannot become new work under a rewritten delivery header" do
    body = Jason.encode!(payload())

    first = request(body, delivery_ref: "delivery-original", event_name: "issue_comment")
    replay = request(body, delivery_ref: "delivery-attacker", event_name: "issue_comment")

    assert first.status == 202
    assert replay.status == 202
    assert Jason.decode!(replay.resp_body)["status"] == "duplicate"
    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 1

    assert {:ok, entry} = Inbox.fetch(Jason.decode!(first.resp_body)["input_ref"])
    assert entry.event_ref =~ "github-body:"
    assert entry.content["delivery_ref"] == "delivery-original"
  end

  test "rejects bad authentication and payload attempts to cross the trusted binding" do
    body = Jason.encode!(payload())
    assert request(body, delivery_ref: "delivery-bad", signature: "sha256=bad").status == 401

    wrong_repository =
      payload()
      |> put_in(["repository", "id"], 100)
      |> Jason.encode!()

    assert request(wrong_repository, delivery_ref: "delivery-wrong-repository").status == 400
  end

  test "one app webhook routes signed events by installation and repository identity" do
    other =
      payload()
      |> put_in(["repository"], %{"full_name" => "octo/other", "id" => 100})
      |> Jason.encode!()

    bindings = %{
      "github-main" => binding!(),
      "github-other" =>
        binding!(%{
          name: "github-other",
          repository_full_name: "octo/other",
          repository_id: 100,
          work_profile: %{
            policy: "github-read-only",
            policy_digest: String.duplicate("b", 64),
            repository_ref: "octo/other"
          }
        })
    }

    conn = request(other, delivery_ref: "delivery-other", bindings: bindings)

    assert conn.status == 202
    assert {:ok, entry} = Inbox.fetch(Jason.decode!(conn.resp_body)["input_ref"])
    assert entry.source_ref == "github-other"
    assert entry.destination_conversation_ref == "github:github-other:repository:100"
    assert entry.repository_ref == "octo/other"
  end

  test "acknowledges signed unsupported events without creating unclaimable work" do
    body = Jason.encode!(%{"zen" => "Keep it logically awesome."})
    conn = request(body, delivery_ref: "delivery-ping", event_name: "ping")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ignored"}
  end

  test "retains review-thread resolution events without starting unrelated work" do
    inbox_count = Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count)

    payload = %{
      "action" => "resolved",
      "installation" => %{"id" => 41},
      "pull_request" => %{"number" => 42, "updated_at" => "2026-08-28T12:00:00Z"},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"},
      "thread" => %{"comments" => [], "node_id" => "PRRT_thread"}
    }

    response =
      request(Jason.encode!(payload),
        delivery_ref: "delivery-review-thread-resolved",
        event_name: "pull_request_review_thread"
      )

    assert response.status == 200

    assert Jason.decode!(response.resp_body) == %{
             "reason" => "no_request_or_rule",
             "status" => "ignored"
           }

    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == inbox_count

    wrong_repository = put_in(payload, ["repository", "full_name"], "octo/other")

    assert request(Jason.encode!(wrong_repository),
             delivery_ref: "delivery-review-thread-wrong-repository",
             event_name: "pull_request_review_thread"
           ).status == 400
  end

  test "an authenticated lifecycle webhook nudges only its exact published pull request" do
    %{publication: publication} =
      PublicationFixture.published!("github-lifecycle-router",
        github_repository: "octo/example",
        pull_request_number: 42
      )

    future = DateTime.add(DateTime.utc_now(), 1, :day)

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^publication.id),
      set: [next_poll_at: future]
    )

    lifecycle =
      payload()
      |> Map.delete("comment")
      |> Map.delete("issue")
      |> Map.put("action", "synchronize")
      |> Map.put("pull_request", %{
        "head" => %{"sha" => publication.commit_sha},
        "number" => 42
      })

    conn =
      request(Jason.encode!(lifecycle),
        delivery_ref: "delivery-pr-lifecycle",
        event_name: "pull_request"
      )

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"status" => "nudged"}
    assert {:ok, claim} = Followups.claim_poll("github-router-lifecycle", 60)
    assert claim.publication.id == publication.id
  end

  test "issue and unmatched pull request lifecycle events enter generic ingress with stable identity" do
    issue = %{
      "action" => "opened",
      "installation" => %{"id" => 41},
      "issue" => %{
        "body" => "@ryker-test Track the adapter lifecycle.",
        "created_at" => "2026-08-28T12:00:00Z",
        "id" => 4_200,
        "number" => 42,
        "title" => "Lifecycle issue",
        "updated_at" => "2026-08-28T12:00:00Z"
      },
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }

    pull = %{
      "action" => "opened",
      "installation" => %{"id" => 41},
      "pull_request" => %{
        "body" => "@ryker-test Unmatched pull request.",
        "created_at" => "2026-08-28T12:00:00Z",
        "head" => %{"sha" => String.duplicate("a", 40)},
        "id" => 4_300,
        "number" => 43,
        "title" => "Unmatched pull",
        "updated_at" => "2026-08-28T12:00:00Z"
      },
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 8, "login" => "reviewer", "type" => "User"}
    }

    issue_response =
      request(Jason.encode!(issue), delivery_ref: "delivery-issue-open", event_name: "issues")

    pull_response =
      request(Jason.encode!(pull),
        delivery_ref: "delivery-pull-open",
        event_name: "pull_request"
      )

    issue_edit =
      issue
      |> put_in(["action"], "edited")
      |> put_in(["issue", "updated_at"], "2026-08-28T12:01:00Z")

    issue_edit_response =
      request(Jason.encode!(issue_edit),
        delivery_ref: "delivery-issue-edit",
        event_name: "issues"
      )

    assert issue_response.status == 202
    assert pull_response.status == 202
    assert issue_edit_response.status == 202

    {:ok, issue_entry} = Inbox.fetch(Jason.decode!(issue_response.resp_body)["input_ref"])
    {:ok, pull_entry} = Inbox.fetch(Jason.decode!(pull_response.resp_body)["input_ref"])

    {:ok, issue_edit_entry} =
      Inbox.fetch(Jason.decode!(issue_edit_response.resp_body)["input_ref"])

    assert issue_entry.native_input_id == issue_edit_entry.native_input_id
    assert issue_entry.revision < issue_edit_entry.revision
    assert issue_entry.destination_thread_ref == "github:github-main:issue:42"
    assert pull_entry.destination_thread_ref == "github:github-main:pull:43"
    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 3
  end

  test "authenticated review feedback resumes the exact published engineering episode" do
    %{episode: episode, publication: publication} =
      PublicationFixture.published!("github-review-feedback-router",
        github_repository: "octo/example",
        pull_request_number: 42
      )

    episode_id = episode.id
    publication_id = publication.id

    body = Jason.encode!(payload())

    conn =
      request(body,
        delivery_ref: "delivery-pr-review-feedback",
        event_name: "issue_comment"
      )

    assert conn.status == 202

    assert %{
             "publication_event_ref" => publication_event_ref,
             "status" => "recorded"
           } = Jason.decode!(conn.resp_body)

    retry =
      request(body,
        delivery_ref: "delivery-pr-review-feedback-retry",
        event_name: "issue_comment"
      )

    assert Jason.decode!(retry.resp_body) == %{
             "publication_event_ref" => publication_event_ref,
             "status" => "duplicate"
           }

    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0

    assert %LifecycleEvent{
             episode_id: ^episode_id,
             kind: "review_feedback",
             publication_id: ^publication_id,
             ref: ^publication_event_ref,
             wakeup_state: :pending
           } = Repo.get_by!(LifecycleEvent, ref: publication_event_ref)

    assert {:ok, claim} = Followups.claim_delivery("github-review-feedback-router", 60)
    assert claim.event.ref == publication_event_ref
    assert {:ok, admitted} = Followups.admit_wakeup(claim.event.ref, claim.lease_ref)
    assert admitted.wakeup_state == :admitted

    assert {:ok, resumed} = Ryker.Episodes.fetch_by_key(episode.key)
    assert resumed.id == episode.id
    assert resumed.state == :working
    assert resumed.owner_ref == "turn:publication-feedback:#{admitted.id}"
    assert Repo.aggregate(Ryker.Episodes.Episode, :count) == 1

    [input_event] =
      Repo.all(
        from(event in Ryker.Episodes.Event,
          where: event.episode_id == ^episode.id and event.kind == :input_admitted,
          order_by: [desc: event.sequence],
          limit: 1
        )
      )

    assert get_in(input_event.payload, ["payload", "content", "event_name"]) ==
             "issue_comment"

    assert get_in(input_event.payload, ["payload", "content", "payload"]) == payload()

    assert get_in(input_event.payload, ["payload", "source", "kind"]) == "github"
    assert get_in(input_event.payload, ["payload", "source_capabilities"]) == %{}

    assert {:ok, work_claim} =
             Custody.claim_next("github-review-feedback-work", 60, :work)

    assert work_claim.episode.id == episode.id
    assert work_claim.session.id == publication.session_id
    assert work_claim.session.policy == "work-contributor"
    assert work_claim.session.repository_ref == "ryker"

    assert {:ok, submission} = SubmissionBuilder.build(work_claim)
    assert submission["context"]["mode"] == "continuation"
    assert [current] = submission["context"]["current_inputs"]["items"]
    assert current["content"]["content"]["event_name"] == "issue_comment"
    assert current["content"]["content"]["payload"] == payload()
  end

  for event_name <- ~w(issue_comment pull_request_review pull_request_review_comment) do
    test "equivalent signed #{event_name} feedback preserves one wakeup and its original source receipt" do
      # Re-encoding the same comment used to create two lifecycle receipts with
      # one native revision: the second wakeup retried an idempotency conflict forever.
      %{episode: episode, publication: publication} =
        PublicationFixture.published!("github-feedback-equivalent-json-#{unquote(event_name)}",
          github_repository: "octo/example",
          pull_request_number: 42
        )

      payload =
        case unquote(event_name) do
          "issue_comment" -> payload()
          "pull_request_review" -> review_payload()
          "pull_request_review_comment" -> review_comment_payload()
        end

      compact = Jason.encode!(payload)
      pretty = Jason.encode!(payload, pretty: true)
      assert compact != pretty
      assert Jason.decode!(compact) == Jason.decode!(pretty)

      original =
        request(compact,
          delivery_ref: "original-feedback-delivery",
          event_name: unquote(event_name)
        )

      assert original.status == 202
      first_ref = Jason.decode!(original.resp_body)["publication_event_ref"]
      first = Repo.get_by!(LifecycleEvent, ref: first_ref)
      source = Repo.get_by!(ConversationObservation, source_input_id: first.id)

      equivalent =
        request(pretty,
          delivery_ref: "equivalent-feedback-delivery",
          event_name: unquote(event_name)
        )

      assert equivalent.status == 202

      assert Jason.decode!(equivalent.resp_body) == %{
               "publication_event_ref" => first_ref,
               "status" => "duplicate"
             }

      assert Repo.get!(LifecycleEvent, first.id) == first
      assert Repo.get!(ConversationObservation, source.id) == source
      assert first.observation["content"]["delivery_ref"] == "original-feedback-delivery"

      assert {:ok, claim} = Followups.claim_delivery("equivalent-feedback", 60)
      assert claim.event.id == first.id
      assert {:ok, admitted} = Followups.admit_wakeup(first.ref, claim.lease_ref)
      assert admitted.wakeup_state == :admitted

      retry =
        request(pretty, delivery_ref: "feedback-after-admission", event_name: unquote(event_name))

      assert Jason.decode!(retry.resp_body) == %{
               "publication_event_ref" => first_ref,
               "status" => "duplicate"
             }

      assert Repo.get!(LifecycleEvent, first.id) == admitted
      assert Repo.get!(ConversationObservation, source.id) == source

      assert Repo.aggregate(
               from(event in LifecycleEvent, where: event.publication_id == ^publication.id),
               :count
             ) == 1

      [wake] =
        Repo.all(
          from(event in Ryker.Episodes.Event,
            where:
              event.episode_id == ^episode.id and event.kind == :input_admitted and
                fragment(
                  "?::jsonb ->> 'turn_ref' = ?",
                  event.payload,
                  ^"turn:publication-feedback:#{first.id}"
                )
          )
        )

      assert [receipt] = LearningSources.for_work_input(wake.payload["payload"])
      assert receipt["source_input_id"] == first.id
      assert {:ok, resumed} = Ryker.Episodes.fetch_by_key(episode.key)
      assert resumed.owner_ref == "turn:publication-feedback:#{first.id}"
    end
  end

  test "equivalent original GitHub redelivery cannot restore superseded learning custody" do
    # A transport retry of old content must reuse its original receipt without
    # replacing the newer edit's learning source or adding a competing wakeup.
    %{publication: publication} =
      PublicationFixture.published!("github-feedback-stale-redelivery",
        github_repository: "octo/example",
        pull_request_number: 42
      )

    original_payload = payload()
    original_body = Jason.encode!(original_payload)
    original = request(original_body, delivery_ref: "original-before-edit")
    assert original.status == 202
    first_ref = Jason.decode!(original.resp_body)["publication_event_ref"]
    first = Repo.get_by!(LifecycleEvent, ref: first_ref)
    source = Repo.get_by!(ConversationObservation, source_input_id: first.id)

    assert {:ok, claim} = Followups.claim_delivery("stale-feedback", 60)
    assert claim.event.id == first.id
    assert {:ok, first} = Followups.admit_wakeup(first.ref, claim.lease_ref)

    edited_payload =
      original_payload
      |> put_in(["action"], "edited")
      |> put_in(["comment", "body"], "Please handle this edge case.")
      |> put_in(["comment", "updated_at"], "2026-08-28T12:01:00Z")

    edit_response = request(Jason.encode!(edited_payload), delivery_ref: "newer-edit")
    assert edit_response.status == 202
    assert Jason.decode!(edit_response.resp_body)["status"] == "recorded"
    edit_ref = Jason.decode!(edit_response.resp_body)["publication_event_ref"]
    assert edit_ref != first_ref
    edit = Repo.get_by!(LifecycleEvent, ref: edit_ref)
    current = Repo.get!(ConversationObservation, source.id)
    assert current.revision > source.revision
    assert current.source_input_id == edit.id
    assert [current_receipt] = LearningSources.for_work_input(edit.observation)
    assert LearningSources.for_work_input(first.observation) == nil

    retry_body = Jason.encode!(original_payload, pretty: true)
    assert retry_body != original_body
    redelivery = request(retry_body, delivery_ref: "original-after-edit")
    assert redelivery.status == 202

    assert Jason.decode!(redelivery.resp_body) == %{
             "publication_event_ref" => first_ref,
             "status" => "duplicate"
           }

    assert Repo.aggregate(
             from(event in LifecycleEvent, where: event.publication_id == ^publication.id),
             :count
           ) == 2

    assert Repo.get!(LifecycleEvent, first.id) == first
    assert first.observation["content"]["delivery_ref"] == "original-before-edit"
    assert Repo.get!(ConversationObservation, source.id) == current
    assert LearningSources.for_work_input(first.observation) == nil
    assert LearningSources.for_work_input(edit.observation) == [current_receipt]
  end

  for {event_name, action} <- [
        {"issue_comment", "deleted"},
        {"pull_request_review_comment", "deleted"},
        {"pull_request_review", "dismissed"}
      ] do
    test "fresh Work consumes only an authenticated #{event_name} #{action} notice" do
      # GitHub retains the original body in deletion webhooks. Blocking that body
      # must not also make the authenticated withdrawal impossible to process.
      PublicationFixture.published!("withdrawal-#{unquote(event_name)}",
        github_repository: "octo/example",
        pull_request_number: 42
      )

      deleted = feedback_payload(unquote(event_name)) |> Map.put("action", unquote(action))
      original_body = get_in(deleted, [feedback_item(unquote(event_name)), "body"])
      event = record_feedback!(deleted, unquote(event_name), "withdrawal")
      claim = claim_feedback!(event)
      assert KnowledgeSnapshot.session_sources(claim.session.id) == []
      assert {:ok, submission} = SubmissionBuilder.build(claim)
      assert [notice] = submission["context"]["current_inputs"]["items"]

      assert notice["content"] == %{
               "event_kind" => "delete",
               "unavailable" => "source_deleted"
             }

      assert notice["current"] == true
      assert is_binary(notice["source_event_id"])
      assert [receipt] = notice["source_dependencies"]
      assert receipt["source_input_id"] == event.id
      refute Jason.encode!(submission) =~ original_body

      assert get_in(Repo.get!(LifecycleEvent, event.id).observation, ["content", "payload"]) ==
               deleted

      assert :ok =
               KnowledgeSnapshot.authorize_submission(
                 claim.episode,
                 claim.session.repository_ref,
                 submission
               )

      for invalid <- [
            Map.delete(notice, "source_event_id"),
            Map.put(notice, "source_event_id", Ecto.UUID.generate()),
            Map.delete(notice, "source_dependencies"),
            Map.put(notice, "source_dependencies", []),
            put_in(notice, ["content", "body"], original_body)
          ] do
        tampered = put_in(submission, ["context", "current_inputs", "items"], [invalid])

        assert {:error, :work_knowledge_context_stale} =
                 KnowledgeSnapshot.authorize_submission(
                   claim.episode,
                   claim.session.repository_ref,
                   tampered
                 )
      end

      assert :ok =
               KnowledgeSnapshot.expose_submission(%{
                 claim
                 | turn: %{claim.turn | submission: submission}
               })
    end

    test "a #{event_name} #{action} notice never rehabilitates a session exposed to its body" do
      PublicationFixture.published!("withdrawal-warm-#{unquote(event_name)}",
        github_repository: "octo/example",
        pull_request_number: 42
      )

      original = feedback_payload(unquote(event_name))
      event = record_feedback!(original, unquote(event_name), "original")
      claim = claim_feedback!(event)
      assert {:ok, submission} = SubmissionBuilder.build(claim)
      claim = %{claim | turn: %{claim.turn | submission: submission}}
      assert :ok = KnowledgeSnapshot.expose_submission(claim)
      assert [_receipt] = KnowledgeSnapshot.session_sources(claim.session.id)

      deleted = Map.put(original, "action", unquote(action))
      deletion = record_feedback!(deleted, unquote(event_name), "deleted")
      assert deletion.id != event.id

      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.authorize_session(claim.episode, claim.session)

      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.expose_submission(claim)
    end
  end

  test "pull request reviews and review-thread comments use the publication subscription" do
    %{publication: publication} =
      PublicationFixture.published!("github-review-kinds-router",
        github_repository: "octo/example",
        pull_request_number: 42
      )

    publication_id = publication.id

    events = [
      {"pull_request_review", review_payload(), "delivery-pr-review"},
      {"pull_request_review_comment", review_comment_payload(), "delivery-pr-review-comment"}
    ]

    Enum.each(events, fn {event_name, event_payload, delivery_ref} ->
      response =
        request(Jason.encode!(event_payload),
          delivery_ref: delivery_ref,
          event_name: event_name
        )

      assert response.status == 202

      assert %{"publication_event_ref" => _, "status" => "recorded"} =
               Jason.decode!(response.resp_body)
    end)

    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0

    assert Repo.aggregate(
             from(event in LifecycleEvent,
               where: event.publication_id == ^publication_id and event.kind == "review_feedback"
             ),
             :count
           ) == 2
  end

  test "acknowledges self-authored and unauthorized comments without queuing model work" do
    self_authored =
      payload()
      |> put_in(["sender"], %{"id" => 99, "login" => "ryker[bot]", "type" => "Bot"})
      |> Jason.encode!()

    unauthorized =
      payload()
      |> put_in(["sender"], %{"id" => 10, "login" => "outsider", "type" => "User"})
      |> Jason.encode!()

    assert request(self_authored, delivery_ref: "delivery-self").status == 200

    assert request(unauthorized,
             delivery_ref: "delivery-outsider",
             repository_access: fn _binding, _payload -> {:error, :actor_not_authorized} end
           ).status == 200

    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0
  end

  test "consumes an authenticated confirmation command without admitting model work" do
    command =
      payload()
      |> put_in(["comment", "body"], "/ryker confirm record:publication_offer:abc123")
      |> Jason.encode!()

    response =
      request(command,
        confirmations: %{
          repositories: %{
            "ryker" => %{
              contributor_policy: %{
                digest: String.duplicate("b", 64),
                name: "ryker-contributor"
              }
            }
          }
        },
        delivery_ref: "delivery-invalid-confirmation"
      )

    assert response.status == 202

    assert Jason.decode!(response.resp_body) == %{
             "confirmation" => %{"status" => "invalid"},
             "status" => "invalid"
           }

    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0
  end

  test "allocates distinct ordered revisions for same-timestamp edits of one GitHub item" do
    created = review_payload()

    first_edit =
      created
      |> put_in(["action"], "edited")
      |> put_in(["review", "body"], "First edit with the immutable submitted timestamp.")

    second_edit =
      created
      |> put_in(["action"], "edited")
      |> put_in(["review", "body"], "Second edit with the immutable submitted timestamp.")

    responses = [
      request(Jason.encode!(created),
        delivery_ref: "delivery-revision-create",
        event_name: "pull_request_review"
      ),
      request(Jason.encode!(first_edit),
        delivery_ref: "delivery-revision-edit-1",
        event_name: "pull_request_review"
      ),
      request(Jason.encode!(second_edit),
        delivery_ref: "delivery-revision-edit-2",
        event_name: "pull_request_review"
      )
    ]

    assert Enum.map(responses, & &1.status) == [202, 202, 202]

    revisions =
      Enum.map(responses, fn response ->
        {:ok, entry} = Inbox.fetch(Jason.decode!(response.resp_body)["input_ref"])
        entry.revision
      end)

    assert [first, second, third] = revisions
    assert first < second
    assert second < third
  end

  test "a delayed equal-timestamp edit cannot overtake an already received delete" do
    deleted = put_in(payload(), ["action"], "deleted")

    delayed_edit =
      payload()
      |> put_in(["action"], "edited")
      |> put_in(["comment", "body"], "This edit was delivered after deletion.")

    delete_response =
      request(Jason.encode!(deleted),
        delivery_ref: "delivery-delete-first",
        event_name: "issue_comment"
      )

    edit_response =
      request(Jason.encode!(delayed_edit),
        delivery_ref: "delivery-edit-late",
        event_name: "issue_comment"
      )

    assert delete_response.status == 202
    assert edit_response.status == 202

    {:ok, delete_entry} = Inbox.fetch(Jason.decode!(delete_response.resp_body)["input_ref"])
    {:ok, edit_entry} = Inbox.fetch(Jason.decode!(edit_response.resp_body)["input_ref"])

    assert delete_entry.revision > edit_entry.revision
  end

  test "requires GitHub delivery metadata, JSON, a signed repository binding, and a bounded body" do
    body = Jason.encode!(payload())

    assert request(body, delivery_ref: nil).status == 400
    assert request("{", delivery_ref: "delivery-json").status == 400

    assert conn(:post, "/v1/github/github-main", body)
           |> Router.call(
             Router.init(
               bindings: %{"github-main" => binding!()},
               bot_login: "ryker-test",
               secret: @secret
             )
           )
           |> Map.fetch!(:status) == 404

    assert request(body,
             content_type: "text/plain",
             delivery_ref: "delivery-media"
           ).status == 415

    oversized = Jason.encode!(%{"body" => String.duplicate("x", 40_001)})
    assert request(oversized, delivery_ref: "delivery-large").status == 413

    missing_event =
      conn(:post, "/v1/github", body)
      |> put_req_header("content-type", "application/problem+json")
      |> put_req_header("x-github-delivery", "delivery-no-event")
      |> put_req_header("x-hub-signature-256", Auth.signature(@secret, body))
      |> Router.call(
        Router.init(
          bindings: %{"github-main" => binding!()},
          bot_login: "ryker-test",
          secret: @secret
        )
      )

    assert missing_event.status == 400
  end

  test "applies the selected binding's body limit and rejects payloads without routing identity" do
    constrained =
      binding!(%{
        max_body_bytes: 1_024,
        name: "github-constrained",
        repository_full_name: "octo/constrained",
        repository_id: 101
      })

    permissive = binding!(%{max_body_bytes: 40_000})

    bindings = %{
      "github-constrained" => constrained,
      "github-main" => permissive
    }

    oversized_for_binding =
      payload()
      |> put_in(["comment", "body"], String.duplicate("x", 2_000))
      |> put_in(["repository"], %{"full_name" => "octo/constrained", "id" => 101})
      |> Jason.encode!()

    assert request(oversized_for_binding,
             bindings: bindings,
             delivery_ref: "delivery-binding-large"
           ).status == 413

    without_identity = payload() |> Map.delete("installation") |> Jason.encode!()

    assert request(without_identity,
             bindings: bindings,
             delivery_ref: "delivery-no-binding-identity"
           ).status == 400
  end

  test "refuses an empty or mismatched binding registry" do
    assert_raise ArgumentError, fn -> Router.init(bindings: %{}, secret: @secret) end

    assert_raise ArgumentError, fn ->
      Router.init(bindings: %{"wrong" => binding!()}, secret: @secret)
    end

    assert_raise ArgumentError, fn ->
      Router.init(bindings: %{"github-main" => binding!()}, secret: "short")
    end

    assert_raise ArgumentError, fn ->
      Router.init(
        bindings: %{
          "github-main" => binding!(),
          "github-alias" => binding!(%{name: "github-alias"})
        },
        secret: @secret
      )
    end
  end

  defp record_feedback!(payload, event_name, delivery_ref) do
    response = request(Jason.encode!(payload), event_name: event_name, delivery_ref: delivery_ref)
    assert response.status == 202

    assert %{"publication_event_ref" => ref, "status" => "recorded"} =
             Jason.decode!(response.resp_body)

    Repo.get_by!(LifecycleEvent, ref: ref)
  end

  defp claim_feedback!(event) do
    assert {:ok, delivery} = Followups.claim_delivery("withdrawal-followup", 60)
    assert delivery.event.id == event.id
    assert {:ok, _} = Followups.admit_wakeup(event.ref, delivery.lease_ref)
    assert {:ok, claim} = Custody.claim_next("withdrawal-work", 60, :work)
    claim
  end

  defp feedback_payload("issue_comment"), do: payload()
  defp feedback_payload("pull_request_review_comment"), do: review_comment_payload()
  defp feedback_payload("pull_request_review"), do: review_payload()
  defp feedback_item("pull_request_review"), do: "review"
  defp feedback_item(_), do: "comment"

  defp request(body, options) do
    event_name = Keyword.get(options, :event_name, "issue_comment")
    delivery_ref = Keyword.get(options, :delivery_ref)
    content_type = Keyword.get(options, :content_type, "application/json")
    signature = Keyword.get(options, :signature, Auth.signature(@secret, body))
    bindings = Keyword.get(options, :bindings, %{"github-main" => binding!()})
    confirmations = Keyword.get(options, :confirmations)

    conn =
      conn(:post, "/v1/github", body)
      |> put_req_header("content-type", content_type)
      |> put_req_header("x-github-event", event_name)
      |> put_req_header("x-hub-signature-256", signature)

    conn =
      if delivery_ref,
        do: put_req_header(conn, "x-github-delivery", delivery_ref),
        else: conn

    repository_access = Keyword.get(options, :repository_access, fn _binding, _payload -> :ok end)

    router_options = [
      bindings: bindings,
      bot_login: "ryker-test",
      repository_access: repository_access,
      secret: @secret
    ]

    router_options =
      if confirmations,
        do: Keyword.put(router_options, :confirmations, confirmations),
        else: router_options

    Router.call(conn, Router.init(router_options))
  end

  defp binding!(overrides \\ %{}) do
    assert {:ok, binding} =
             %{
               installation_id: 41,
               name: "github-main",
               repository_full_name: "octo/example",
               repository_id: 99,
               ryker_actor_id: 99,
               secret: @secret,
               work_profile: %{
                 policy: "github-read-only",
                 policy_digest: String.duplicate("a", 64),
                 repository_ref: "octo/example"
               }
             }
             |> Map.merge(overrides)
             |> Binding.new()

    binding
  end

  defp payload do
    %{
      "action" => "created",
      "comment" => %{
        "body" => "@ryker-test Please update this implementation.",
        "created_at" => "2026-08-28T12:00:00Z",
        "id" => 9001,
        "updated_at" => "2026-08-28T12:00:00Z"
      },
      "installation" => %{"id" => 41},
      "issue" => %{"number" => 42, "pull_request" => %{}},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end

  defp review_payload do
    %{
      "action" => "submitted",
      "installation" => %{"id" => 41},
      "pull_request" => %{"number" => 42},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "review" => %{
        "body" => "@ryker-test Initial review.",
        "id" => 7_001,
        "submitted_at" => "2026-08-28T12:00:00Z"
      },
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end

  defp review_comment_payload do
    %{
      "action" => "created",
      "comment" => %{
        "body" => "@ryker-test " <> String.duplicate("Please handle this edge case. ", 700),
        "created_at" => "2026-08-28T12:00:00Z",
        "id" => 7_002,
        "updated_at" => "2026-08-28T12:00:00Z"
      },
      "installation" => %{"id" => 41},
      "pull_request" => %{"number" => 42},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 8, "login" => "reviewer", "type" => "User"}
    }
  end
end
