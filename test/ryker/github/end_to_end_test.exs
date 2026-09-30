defmodule Ryker.GitHub.EndToEndTest do
  use Ryker.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Plug.Conn
  import Plug.Test

  alias Ryker.Admission.Dispatcher, as: AdmissionDispatcher
  alias Ryker.Delivery.{Adapters, RoutingResponse}
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.GitHub.{Auth, Binding, Client, Publisher, Router}
  alias Ryker.Ingress.Inbox
  alias Ryker.Publication.{FollowupDispatcher, LifecycleEvent}
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Slack.Publisher, as: SlackPublisher
  alias Ryker.TestSupport.{FakeCoopAPI, FakeSlackAPI, FakeWorkCoopAPI, GitHubRequester}
  alias Ryker.Work.{Custody, Dispatcher, Executor, Final, Session, SubmissionBuilder, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @secret String.duplicate("s", 32)

  defmodule FollowupStatusAPI do
    def get_publication_status(_client, _repository, _number), do: {:error, :not_used}
  end

  test "a signed GitHub PR comment reaches Work and settles in the exact repository thread" do
    payload = payload(9_001, "@ryker-test Please update this implementation.")
    response = post(payload, "github-delivery-message")
    assert response.status == 202

    {:ok, admission_fake} = FakeCoopAPI.start_link([decision("start_episode")])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission_fake, "message"))

    assert admitted.result.entry.source_kind == "github"
    assert admitted.result.episode.destination_transport == "github"

    assert admitted.result.episode.destination_conversation_ref ==
             "github:github-main:repository:99"

    assert admitted.result.episode.destination_thread_ref == "github:github-main:pull:42"

    assert %Session{
             policy: "github-conversation-read",
             policy_digest: digest,
             repository_ref: "ryker"
           } =
             Repo.get_by!(Session, episode_id: admitted.result.episode.id)

    assert digest == String.duplicate("a", 64)

    {:ok, work_fake} = FakeWorkCoopAPI.start_link([work_reply("Implemented and verified.")])

    assert {:ok, {:executed, work_execution}} =
             Dispatcher.run_once(work_options(work_fake, "message"))

    assert work_execution.turn.status == :delivery_pending
    assert [submitted] = FakeWorkCoopAPI.state(work_fake).submissions
    assert submitted.schema == Final.json_schema()

    assert [work_input] = work_execution.turn.submission["context"]["inputs"]["items"]
    assert work_input["content"]["content"]["payload"] == payload

    {:ok, requester} =
      GitHubRequester.start([
        github_response(200, []),
        github_response(201, %{"body" => "Implemented and verified.", "id" => 9_100})
      ])

    assert {:ok, {:delivered, :message, delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options(:message, requester, "message"))

    settled = Repo.get!(Turn, work_execution.turn.id)
    assert settled.status == :settled
    assert settled.delivery_ref == delivery_ref
    assert settled.external_receipt["message_ref"] == "github:pull_request_review:9100"

    assert [
             {:get, "/repos/octo/example/pulls/42/reviews?per_page=100&page=1", nil, _},
             {:post, "/repos/octo/example/pulls/42/reviews",
              %{"body" => body, "event" => "COMMENT"}, _}
           ] = GitHubRequester.requests(requester)

    assert body =~ "Implemented and verified."
    assert body =~ Publisher.marker(delivery_ref)

    echo =
      payload(9_100, body)
      |> put_in(["sender"], %{"id" => 99, "login" => "ryker[bot]", "type" => "Bot"})

    assert post(echo, "github-delivery-self-echo").status == 200
    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 1
  end

  test "a signed GitHub comment can become one durable native emoji reaction" do
    response =
      post(
        payload(9_002, "@ryker-test Looks good to me."),
        "github-delivery-reaction"
      )

    assert response.status == 202

    {:ok, admission_fake} = FakeCoopAPI.start_link([decision("react", "rocket")])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission_fake, "reaction"))

    assert admitted.result.entry.decision_action == :react

    assert %RoutingResponse{status: :pending} =
             Repo.get_by!(RoutingResponse, input_id: admitted.result.entry.id)

    {:ok, requester} = GitHubRequester.start([github_response(201, %{"id" => 77})])

    assert {:ok, {:delivered, :routing, delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options(:routing, requester, "reaction"))

    delivered = Repo.get_by!(RoutingResponse, input_id: admitted.result.entry.id)
    assert delivered.status == :delivered
    assert delivered.delivery_ref == delivery_ref

    assert [
             {:post, "/repos/octo/example/issues/comments/9002/reactions",
              %{"content" => "rocket"}, _}
           ] = GitHubRequester.requests(requester)
  end

  # Andrew, 2026-09-28, of three comments and a review on AndrewDryga/test#2:
  # "gh integration doesn't work?" Once GitHub's events reached Ryker, the
  # task answered them in its Slack thread, where nobody on the pull request
  # would see it; he asked for the answer on GitHub, where it was asked. An
  # inline comment is answered in its own review thread, in the task's
  # original Work session, and Slack gets nothing.
  test "an inline review on a Slack task's pull request is answered in its review thread" do
    %{episode: episode, publication: publication} =
      PublicationFixture.published!("github-review-e2e",
        conversation_ref: "slack:TB14ADAF3E1AF:C456",
        github_repository: "octo/example",
        pull_request_number: 42,
        thread_ref: "1787832001.000200"
      )

    session = Repo.get_by!(Session, episode_id: episode.id, generation: 1) |> WorkerJob.pin!()
    payload = review_comment_payload(9_003, "Please handle the nil case before merge.")
    response = post(payload, "github-delivery-review-feedback", "pull_request_review_comment")

    assert response.status == 202

    assert %{"publication_event_ref" => event_ref, "status" => "recorded"} =
             Jason.decode!(response.resp_body)

    assert Repo.aggregate(Inbox.Entry, :count) == 0

    assert %LifecycleEvent{
             episode_id: episode_id,
             publication_id: publication_id,
             wakeup_state: :pending
           } = Repo.get_by!(LifecycleEvent, ref: event_ref)

    assert episode_id == episode.id
    assert publication_id == publication.id

    {:ok, slack} =
      FakeSlackAPI.start_link(
        observer: self(),
        message_ref: fn n -> "1787918400.000#{n}" end
      )

    adapters = slack_adapters(slack)

    assert {:ok, {:executed, %{phase: :delivery}}} =
             FollowupDispatcher.run_once(
               executor_options: [
                 adapters: adapters,
                 api: FollowupStatusAPI,
                 client: :not_used
               ],
               interval_seconds: 120,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "github-review-followup-e2e"
             )

    assert_receive {
      :slack_posted,
      "C456",
      "1787832001.000200",
      %{"message" => lifecycle_message},
      _lifecycle_delivery_ref,
      _lifecycle_message_ref
    }

    assert lifecycle_message =~ "Authenticated GitHub review feedback"

    assert {:ok, resumed} = Ryker.Episodes.fetch_by_key(episode.key)
    assert resumed.id == episode.id
    assert resumed.destination_transport == "slack"
    assert resumed.destination_conversation_ref == "slack:TB14ADAF3E1AF:C456"
    assert resumed.destination_thread_ref == "1787832001.000200"
    assert resumed.state == :working

    {:ok, work_fake} =
      FakeWorkCoopAPI.start_link(
        [work_reply("Handled the nil case, added coverage, and updated the review branch.")],
        changes: [workspace_changes()]
      )

    FakeWorkCoopAPI.update(work_fake, fn state ->
      remote_session =
        state.session
        |> Map.merge(WorkerJob.receipt(session))
        |> Map.merge(%{
          "id" => session.coop_session_id,
          "revision" => 2,
          "state" => "open"
        })

      %{state | session: remote_session, turn: nil}
    end)

    assert {:ok, work_claim} =
             Custody.claim_next("github-review-work-e2e", 60, :work)

    assert work_claim.episode.id == episode.id
    assert work_claim.session.id == session.id

    assert {:ok, submission} = SubmissionBuilder.build(work_claim)

    assert {:ok, frozen_turn} =
             Custody.freeze_submission(
               work_claim.episode.id,
               work_claim.turn.turn_ref,
               work_claim.lease_ref,
               submission
             )

    work_claim = %{work_claim | turn: frozen_turn}

    assert {:ok, _goal_state} =
             Records.create(
               Records.token(work_claim.turn),
               "github-review-goal-complete",
               "goal_state",
               %{
                 "detail" => "The review correction is committed with focused coverage.",
                 "goal_id" => "engineering-github-review-e2e",
                 "state" => "completed"
               }
             )

    executor_options =
      work_options(work_fake, "review-feedback")
      |> Keyword.fetch!(:executor_options)
      |> Keyword.put(:lease_seconds, 60)

    assert {:ok, execution} = Executor.run(work_claim, executor_options)

    assert execution.turn.status == :delivery_pending
    assert execution.turn.session_id == session.id
    assert Repo.aggregate(Session, :count, :id) == 1

    work_state = FakeWorkCoopAPI.state(work_fake)
    assert work_state.create_count == 0
    assert [submission] = work_state.submissions
    assert work_state.turn["session_id"] == session.coop_session_id
    assert submission.expected_revision == 2

    assert [current] = execution.turn.submission["context"]["current_inputs"]["items"]
    assert current["content"]["content"]["event_name"] == "pull_request_review_comment"
    assert current["content"]["content"]["payload"] == payload

    assert Custody.Delivery.answer_target(work_claim.episode, execution.turn) == %{
             "conversation_ref" => "github:github-main:repository:99",
             "thread_ref" => "github:github-main:pull:42:review-thread:9000",
             "transport" => "github"
           }

    # A Slack mention names nobody on GitHub, so the answer may make none.
    assert Custody.Delivery.answer_mentions(work_claim.episode, execution.turn) == nil

    {:ok, requester} =
      GitHubRequester.start([
        github_response(200, []),
        github_response(201, %{"id" => 9_200})
      ])

    assert {:ok, {:delivered, :message, final_delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(
               adapters: slack_and_github_adapters(slack, requester),
               kind: :message,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "github-review-github-result-e2e"
             )

    assert [
             {:get, "/repos/octo/example/pulls/42/comments?per_page=100&page=1", nil, _},
             {:post, "/repos/octo/example/pulls/42/comments/9000/replies", %{"body" => body}, _}
           ] = GitHubRequester.requests(requester)

    assert body =~ "Handled the nil case, added coverage, and updated the review branch."
    assert body =~ Publisher.marker(final_delivery_ref)
    refute_receive {:slack_posted, _channel, _thread, _document, ^final_delivery_ref, _ref}

    assert %Turn{status: :settled, external_receipt: receipt} =
             Repo.get!(Turn, execution.turn.id)

    assert receipt["transport"] == "github"
    assert receipt["thread_ref"] == "github:github-main:pull:42:review-thread:9000"
    assert receipt["message_ref"] == "github:pull_request_review_comment:9200"
  end

  defp post(payload, delivery_ref, event_name \\ "issue_comment") do
    body = Jason.encode!(payload)

    conn(:post, "/v1/github", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-delivery", delivery_ref)
    |> put_req_header("x-github-event", event_name)
    |> put_req_header("x-hub-signature-256", Auth.signature(@secret, body))
    |> Router.call(
      Router.init(
        bindings: %{"github-main" => binding!()},
        bot_login: "ryker-test",
        repository_access: fn _binding, _payload -> :ok end,
        secret: @secret
      )
    )
  end

  defp binding! do
    assert {:ok, binding} =
             Binding.new(%{
               installation_id: 41,
               name: "github-main",
               repository_full_name: "octo/example",
               repository_id: 99,
               ryker_actor_id: 99,
               secret: @secret,
               work_profile: %{
                 policy: "github-conversation-read",
                 policy_digest: String.duplicate("a", 64),
                 repository_ref: "ryker"
               }
             })

    binding
  end

  defp payload(comment_id, body) do
    %{
      "action" => "created",
      "comment" => %{
        "body" => body,
        "created_at" => "2026-08-28T12:00:00Z",
        "id" => comment_id,
        "updated_at" => "2026-08-28T12:00:00Z"
      },
      "installation" => %{"id" => 41},
      "issue" => %{"number" => 42, "pull_request" => %{}},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end

  defp review_comment_payload(comment_id, body) do
    %{
      "action" => "created",
      "comment" => %{
        "body" => body,
        "created_at" => "2026-08-28T12:00:00Z",
        "id" => comment_id,
        "in_reply_to_id" => 9_000,
        "line" => 17,
        "path" => "lib/example.ex",
        "updated_at" => "2026-08-28T12:00:00Z"
      },
      "installation" => %{"id" => 41},
      "pull_request" => %{"number" => 42},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end

  defp workspace_changes do
    %{
      "base_commit" => "base-commit",
      "committed" => [%{"path" => "lib/example.ex", "status" => "modified"}],
      "conflicts" => [],
      "fork_head" => "review-fix-commit",
      "fork_tree" => "review-fix-tree",
      "parent_divergence" => %{
        "ahead" => 1,
        "base_to_fork" => 1,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "parent_head" => "parent-head",
      "patch_bytes" => 0,
      "patch_has_more" => false,
      "patch_next_offset" => 0,
      "patch_offset" => 0,
      "staged" => [],
      "truncated" => false,
      "unstaged" => [],
      "untracked" => []
    }
  end

  defp slack_adapters(slack) do
    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"TB14ADAF3E1AF" => %{api: FakeSlackAPI, client: slack}}},
                 message_publisher: SlackPublisher,
                 reaction_publisher: SlackPublisher
               }
             })

    adapters
  end

  defp slack_and_github_adapters(slack, requester) do
    assert {:ok, client} = Client.new(http: requester, requester: GitHubRequester)

    assert {:ok, adapters} =
             Adapters.new(%{
               "github" => %{
                 binding: %{
                   bindings: %{
                     "github-main" => %{
                       api: Client,
                       client: client,
                       repository_full_name: "octo/example",
                       repository_id: 99
                     }
                   }
                 },
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               },
               "slack" => %{
                 binding: %{workspaces: %{"TB14ADAF3E1AF" => %{api: FakeSlackAPI, client: slack}}},
                 message_publisher: SlackPublisher,
                 reaction_publisher: SlackPublisher
               }
             })

    adapters
  end

  defp admission_options(fake, suffix) do
    [
      executor_options: [
        api: FakeCoopAPI,
        client: fake,
        max_polls: 10,
        now: fn -> @now end,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 300,
      now: fn -> @now end,
      retry_base_ms: 1_000,
      retry_max_ms: 60_000,
      worker_ref: "github-admission-e2e:#{suffix}"
    ]
  end

  defp work_options(fake, suffix) do
    [
      executor_options: [
        api: FakeWorkCoopAPI,
        client: fake,
        max_block_ms: 1_000,
        max_polls: 20,
        monotonic_ms: fn -> 0 end,
        now: fn -> @now end,
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "github-work-e2e:#{suffix}"
    ]
  end

  defp delivery_options(kind, requester, suffix) do
    assert {:ok, client} = Client.new(http: requester, requester: GitHubRequester)

    publisher_binding = %{
      bindings: %{
        "github-main" => %{
          api: Client,
          client: client,
          repository_full_name: "octo/example",
          repository_id: 99
        }
      }
    }

    assert {:ok, adapters} =
             Adapters.new(%{
               "github" => %{
                 binding: publisher_binding,
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    [
      adapters: adapters,
      kind: kind,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "github-delivery-e2e:#{suffix}"
    ]
  end

  defp decision(action, emoji_name \\ nil)

  defp decision("react", emoji_name) do
    Jason.encode!(%{
      "action" => "react",
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => [emoji_name],
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "A native reaction is enough acknowledgement for this comment.",
      "work_class" => nil
    })
  end

  defp decision(action, _emoji_name) do
    Jason.encode!(%{
      "action" => action,
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => nil,
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "This comment requests work and needs a new episode.",
      "work_class" => if(action == "reply", do: "conversational", else: "standard")
    })
  end

  defp work_reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp github_response(status, body),
    do: {:ok, %{body: body, headers: [], status: status}}
end
