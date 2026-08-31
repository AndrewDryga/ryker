defmodule Responder.GitHub.RouterTest do
  use Responder.DataCase, async: true

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.GitHub.{Auth, Binding, Router}
  alias Responder.Ingress.Inbox
  alias Responder.Publication.{Followup, Followups, LifecycleEvent}
  alias Responder.Work.{Custody, SubmissionBuilder}

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

  test "a captured signed body cannot become new work under a rewritten delivery header" do
    body = Jason.encode!(payload())

    first = request(body, delivery_ref: "delivery-original", event_name: "issue_comment")
    replay = request(body, delivery_ref: "delivery-attacker", event_name: "issue_comment")

    assert first.status == 202
    assert replay.status == 202
    assert Jason.decode!(replay.resp_body)["status"] == "duplicate"
    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 1

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

    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 0

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

    assert {:ok, resumed} = Responder.Episodes.fetch_by_key(episode.key)
    assert resumed.id == episode.id
    assert resumed.state == :working
    assert resumed.owner_ref == "turn:publication-feedback:#{admitted.id}"
    assert Repo.aggregate(Responder.Episodes.Episode, :count) == 1

    [input_event] =
      Repo.all(
        from(event in Responder.Episodes.Event,
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
    assert work_claim.session.repository_ref == "responder"

    assert {:ok, submission} = SubmissionBuilder.build(work_claim)
    assert submission["context"]["mode"] == "continuation"
    assert [current] = submission["context"]["current_inputs"]["items"]
    assert current["content"]["content"]["event_name"] == "issue_comment"
    assert current["content"]["content"]["payload"] == payload()
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

    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 0

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
      |> put_in(["sender"], %{"id" => 99, "login" => "responder[bot]", "type" => "Bot"})
      |> Jason.encode!()

    unauthorized =
      payload()
      |> put_in(["sender"], %{"id" => 10, "login" => "outsider", "type" => "User"})
      |> Jason.encode!()

    assert request(self_authored, delivery_ref: "delivery-self").status == 200
    assert request(unauthorized, delivery_ref: "delivery-outsider").status == 200
    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 0
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
           |> Router.call(Router.init(bindings: %{"github-main" => binding!()}, secret: @secret))
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
      |> Router.call(Router.init(bindings: %{"github-main" => binding!()}, secret: @secret))

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

  defp request(body, options) do
    event_name = Keyword.get(options, :event_name, "issue_comment")
    delivery_ref = Keyword.get(options, :delivery_ref)
    content_type = Keyword.get(options, :content_type, "application/json")
    signature = Keyword.get(options, :signature, Auth.signature(@secret, body))
    bindings = Keyword.get(options, :bindings, %{"github-main" => binding!()})

    conn =
      conn(:post, "/v1/github", body)
      |> put_req_header("content-type", content_type)
      |> put_req_header("x-github-event", event_name)
      |> put_req_header("x-hub-signature-256", signature)

    conn =
      if delivery_ref,
        do: put_req_header(conn, "x-github-delivery", delivery_ref),
        else: conn

    Router.call(conn, Router.init(bindings: bindings, secret: @secret))
  end

  defp binding!(overrides \\ %{}) do
    assert {:ok, binding} =
             %{
               authorized_actor_ids: [7, 8],
               installation_id: 41,
               name: "github-main",
               repository_full_name: "octo/example",
               repository_id: 99,
               responder_actor_id: 99,
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
        "body" => "Please update this implementation.",
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
        "body" => "Initial review.",
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
        "body" => String.duplicate("Please handle this edge case. ", 700),
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
