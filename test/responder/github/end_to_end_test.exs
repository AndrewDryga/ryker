defmodule Responder.GitHub.EndToEndTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Plug.Conn
  import Plug.Test

  alias Responder.Admission.Dispatcher, as: AdmissionDispatcher
  alias Responder.Delivery.{Adapters, Reaction, ReactionCustody}
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.GitHub.{Auth, Binding, Client, Publisher, Router}
  alias Responder.Ingress.Inbox
  alias Responder.Publication.{FollowupDispatcher, LifecycleEvent}
  alias Responder.Repo
  alias Responder.Slack.Publisher, as: SlackPublisher
  alias Responder.State.Records
  alias Responder.TestSupport.{FakeCoopAPI, FakeWorkCoopAPI}
  alias Responder.Work.{Custody, Dispatcher, Executor, Final, Session, SubmissionBuilder, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @secret String.duplicate("s", 32)

  defmodule GitHubRequester do
    def start(responses), do: Agent.start_link(fn -> %{requests: [], responses: responses} end)

    def request(agent, method, path, document, headers) do
      Agent.get_and_update(agent, fn state ->
        [response | remaining] = state.responses
        request = {method, path, document, headers}
        {response, %{state | requests: state.requests ++ [request], responses: remaining}}
      end)
    end

    def requests(agent), do: Agent.get(agent, & &1.requests)
  end

  defmodule SlackAPI do
    @behaviour Responder.Slack.API

    def start_link(observer), do: Agent.start_link(fn -> %{count: 0, observer: observer} end)

    @impl true
    def find_message(_client, _channel, _thread, _delivery_ref), do: :not_found

    @impl true
    def post_message(agent, channel, thread, document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        count = state.count + 1
        send(state.observer, {:slack_posted, channel, thread, document, delivery_ref})
        {{:ok, "1787918400.000#{count}"}, %{state | count: count}}
      end)
    end

    @impl true
    def update_message(_client, _channel, _message_ref, _document, _delivery_ref),
      do: {:error, :not_used}

    @impl true
    def find_files(_client, _channel, _thread, _filenames), do: :not_found

    @impl true
    def upload_files(_client, _channel, _thread, _body, _delivery_ref, _files),
      do: {:error, :not_used}

    @impl true
    def add_reaction(_client, _channel, _message_ref, _emoji_name), do: {:error, :not_used}
  end

  defmodule FollowupStatusAPI do
    def get_publication_status(_client, _repository, _number), do: {:error, :not_used}
  end

  test "a signed GitHub PR comment reaches Work and settles in the exact repository thread" do
    payload = payload(9_001, "Please update this implementation.")
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
             repository_ref: "responder"
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
             Responder.Delivery.Dispatcher.run_once(
               delivery_options(:message, requester, "message")
             )

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
      |> put_in(["sender"], %{"id" => 99, "login" => "responder[bot]", "type" => "Bot"})

    assert post(echo, "github-delivery-self-echo").status == 200
    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 1
  end

  test "a signed GitHub comment can become one durable native emoji reaction" do
    response = post(payload(9_002, "Looks good to me."), "github-delivery-reaction")
    assert response.status == 202

    {:ok, admission_fake} = FakeCoopAPI.start_link([decision("react", "rocket")])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission_fake, "reaction"))

    assert admitted.result.entry.decision_action == :react

    assert %Reaction{status: :pending} =
             Repo.get_by!(Reaction, input_id: admitted.result.entry.id)

    {:ok, requester} = GitHubRequester.start([github_response(201, %{"id" => 77})])

    assert {:ok, {:delivered, :reaction, delivery_ref}} =
             Responder.Delivery.Dispatcher.run_once(
               delivery_options(:reaction, requester, "reaction")
             )

    assert {:ok, delivered} = ReactionCustody.fetch_by_input(admitted.result.entry.id)
    assert delivered.status == :delivered
    assert delivered.delivery_ref == delivery_ref

    assert [
             {:post, "/repos/octo/example/issues/comments/9002/reactions",
              %{"content" => "rocket"}, _}
           ] = GitHubRequester.requests(requester)
  end

  test "a signed inline review continues the Slack engineering task in its original Work session" do
    %{episode: episode, publication: publication} =
      PublicationFixture.published!("github-review-e2e",
        conversation_ref: "slack:TB14ADAF3E1AF:C456",
        github_repository: "octo/example",
        pull_request_number: 42,
        thread_ref: "1787832001.000200"
      )

    session = Repo.get_by!(Session, episode_id: episode.id, generation: 1)
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

    {:ok, slack} = SlackAPI.start_link(self())
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
      _lifecycle_delivery_ref
    }

    assert lifecycle_message =~ "Authenticated GitHub review feedback"

    assert {:ok, resumed} = Responder.Episodes.fetch_by_key(episode.key)
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
        Map.merge(state.session, %{
          "external_ref" => session.external_ref,
          "id" => session.coop_session_id,
          "policy" => session.policy,
          "policy_digest" => session.policy_digest,
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

    assert {:ok, {:delivered, :message, final_delivery_ref}} =
             Responder.Delivery.Dispatcher.run_once(
               adapters: adapters,
               kind: :message,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "github-review-slack-result-e2e"
             )

    assert_receive {
      :slack_posted,
      "C456",
      "1787832001.000200",
      %{"message" => "Handled the nil case, added coverage, and updated the review branch."},
      ^final_delivery_ref
    }

    assert %Turn{status: :settled, external_receipt: receipt} =
             Repo.get!(Turn, execution.turn.id)

    assert receipt["transport"] == "slack"
    assert receipt["conversation_ref"] == "slack:TB14ADAF3E1AF:C456"
    assert receipt["thread_ref"] == "1787832001.000200"
  end

  defp post(payload, delivery_ref, event_name \\ "issue_comment") do
    body = Jason.encode!(payload)

    conn(:post, "/v1/github", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-delivery", delivery_ref)
    |> put_req_header("x-github-event", event_name)
    |> put_req_header("x-hub-signature-256", Auth.signature(@secret, body))
    |> Router.call(Router.init(bindings: %{"github-main" => binding!()}, secret: @secret))
  end

  defp binding! do
    assert {:ok, binding} =
             Binding.new(%{
               authorized_actor_ids: [7, 8],
               installation_id: 41,
               name: "github-main",
               repository_full_name: "octo/example",
               repository_id: 99,
               responder_actor_id: 99,
               secret: @secret,
               work_profile: %{
                 policy: "github-conversation-read",
                 policy_digest: String.duplicate("a", 64),
                 repository_ref: "responder"
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
                 binding: %{workspaces: %{"TB14ADAF3E1AF" => %{api: SlackAPI, client: slack}}},
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
      "reaction" => %{"emoji_name" => emoji_name},
      "relation" => "unrelated",
      "reason" => "A native reaction is enough acknowledgement for this comment.",
      "work_class" => nil
    })
  end

  defp decision(action, _emoji_name) do
    Jason.encode!(%{
      "action" => action,
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
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
