defmodule Responder.GitHub.PublisherTest do
  use ExUnit.Case, async: true

  alias Responder.Delivery.Request
  alias Responder.GitHub.Publisher

  defmodule FakeAPI do
    @behaviour Responder.GitHub.API

    def start(options \\ %{}), do: Agent.start_link(fn -> Map.merge(initial(), options) end)

    @impl true
    def find_issue_comment(agent, repository, number, marker) do
      find(agent, {:issue, repository, number, marker})
    end

    @impl true
    def create_issue_comment(agent, repository, number, body) do
      create(agent, {:issue, repository, number}, body, 9_001)
    end

    @impl true
    def update_issue_comment(agent, repository, id, body) do
      update(agent, {:issue_comment, repository, id}, body)
    end

    @impl true
    def find_pull_review(agent, repository, number, marker) do
      find(agent, {:pull_review, repository, number, marker})
    end

    @impl true
    def create_pull_review(agent, repository, number, body) do
      create(agent, {:pull_review, repository, number}, body, 9_100)
    end

    @impl true
    def update_pull_review(agent, repository, number, id, body) do
      update(agent, {:pull_review, repository, number, id}, body)
    end

    @impl true
    def find_review_reply(agent, repository, number, root_id, marker) do
      find(agent, {:review, repository, number, root_id, marker})
    end

    @impl true
    def create_review_reply(agent, repository, number, root_id, body) do
      create(agent, {:review, repository, number, root_id}, body, 8_002)
    end

    @impl true
    def update_review_comment(agent, repository, id, body) do
      update(agent, {:review_comment, repository, id}, body)
    end

    @impl true
    def add_issue_comment_reaction(agent, repository, id, emoji_name) do
      react(agent, {:issue_comment, repository, id, emoji_name})
    end

    @impl true
    def add_review_comment_reaction(agent, repository, id, emoji_name) do
      react(agent, {:review_comment, repository, id, emoji_name})
    end

    def state(agent), do: Agent.get(agent, & &1)

    defp find(agent, key) do
      Agent.get_and_update(agent, fn state ->
        result =
          case Map.fetch(state.messages, key) do
            {:ok, id} -> {:ok, id}
            :error -> :not_found
          end

        {result, %{state | finds: state.finds + 1}}
      end)
    end

    defp create(agent, base_key, body, id) do
      Agent.get_and_update(agent, fn state ->
        [marker] = Regex.run(~r/<!-- responder-delivery:[a-f0-9]{64} -->/, body)
        key = Tuple.insert_at(base_key, tuple_size(base_key), marker)
        messages = Map.put(state.messages, key, id)
        state = %{state | creates: [{base_key, body} | state.creates], messages: messages}

        if state.lose_create_response,
          do: {{:error, :socket_closed}, %{state | lose_create_response: false}},
          else: {{:ok, id}, state}
      end)
    end

    defp react(agent, reaction) do
      Agent.update(agent, fn state ->
        %{state | reactions: MapSet.put(state.reactions, reaction)}
      end)
    end

    defp update(agent, target, body) do
      Agent.update(agent, fn state -> %{state | updates: [{target, body} | state.updates]} end)
    end

    defp initial do
      %{
        creates: [],
        finds: 0,
        lose_create_response: false,
        messages: %{},
        reactions: MapSet.new(),
        updates: []
      }
    end
  end

  test "a lost native pull review response reconciles its opaque marker exactly once" do
    {:ok, api} = FakeAPI.start(%{lose_create_response: true})

    request =
      message_request(
        "github:github-main:pull:42",
        "Done. @octocat please check with @octo/platform."
      )

    binding = publisher_binding(api)

    assert Publisher.publish_message(request, binding) ==
             {:error, {:delivery_uncertain, :socket_closed}}

    assert {:ok, receipt} = Publisher.publish_message(request, binding)
    assert receipt["message_ref"] == "github:pull_request_review:9100"
    assert receipt["conversation_ref"] == request.conversation_ref

    state = FakeAPI.state(api)
    assert length(state.creates) == 1
    assert state.finds == 2
    assert [{_target, body}] = state.creates
    assert body =~ "Done. @\u200Boctocat please check with @\u200Bocto/platform."
    refute body =~ "@octocat"
    refute body =~ "@octo/platform"
    assert body =~ Publisher.marker(request.ref)
  end

  test "an inline review-thread reply stays in its exact pull request thread" do
    {:ok, api} = FakeAPI.start()
    request = message_request("github:github-main:pull:42:review-thread:8001")

    assert {:ok, receipt} = Publisher.publish_message(request, publisher_binding(api))
    assert receipt["message_ref"] == "github:pull_request_review_comment:8002"

    assert [{{:review, "octo/example", 42, 8_001}, _body}] = FakeAPI.state(api).creates
  end

  test "a GitHub reply preserves the authoritative Emisar approval record" do
    {:ok, api} = FakeAPI.start()

    assert {:ok, request} =
             Request.new(%{
               conversation_ref: "github:github-main:repository:99",
               document: %{
                 "message" => "The action has not run.",
                 "records" => [
                   %{
                     "kind" => "emisar_approval",
                     "payload" => %{
                       "action_id" => "nomad.alloc_restart",
                       "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
                       "expires_at" => "2099-08-29T12:00:00.000000Z",
                       "operation_id" => "op-1",
                       "pack_ref" => "nomad@1#sha256:abc",
                       "request_id" => "apr-1",
                       "run_id" => "run-1",
                       "runner_ref" => "production-runner",
                       "status" => "pending_approval"
                     },
                     "ref" => "record:emisar_approval:abc123",
                     "status" => "open"
                   }
                 ]
               },
               kind: :message,
               ref: "delivery:github:emisar-approval",
               source_item_ref: nil,
               thread_ref: "github:github-main:pull:42",
               transport: "github"
             })

    assert {:ok, _receipt} = Publisher.publish_message(request, publisher_binding(api))
    assert [{{:pull_review, "octo/example", 42}, body}] = FakeAPI.state(api).creates
    assert body =~ "Approval required in Emisar"
    assert body =~ "https://emisar.example/app/acme/approvals/apr-1"
    assert body =~ "GitHub cannot approve this action"
  end

  test "GitHub issue and review comments expose only GitHub's supported emoji operation" do
    {:ok, api} = FakeAPI.start()

    issue = reaction_request("issue_comment", 9_001, "+1")
    review = reaction_request("pull_request_review_comment", 8_002, "rocket")

    assert {:ok, issue_receipt} = Publisher.publish_reaction(issue, publisher_binding(api))
    assert issue_receipt["message_ref"] == "github:issue_comment:9001"
    assert {:ok, _review_receipt} = Publisher.publish_reaction(review, publisher_binding(api))

    assert FakeAPI.state(api).reactions ==
             MapSet.new([
               {:issue_comment, "octo/example", 9_001, "+1"},
               {:review_comment, "octo/example", 8_002, "rocket"}
             ])
  end

  test "the trusted repository binding rejects a crossed repository identity" do
    {:ok, api} = FakeAPI.start()
    request = message_request("github:github-main:pull:42")
    crossed = put_in(publisher_binding(api), [:bindings, "github-main", :repository_id], 100)

    assert Publisher.publish_message(request, crossed) ==
             {:error, {:github_repository_not_configured, "github-main"}}
  end

  test "a governed status refresh edits the exact GitHub comment and retains its marker" do
    {:ok, api} = FakeAPI.start()
    request = message_request("github:github-main:pull:42")

    document = %{
      "emisar_approval_status" => approval_status("denied")
    }

    assert :ok =
             Publisher.update_message(
               request,
               "github:pull_request_review:9100",
               document,
               publisher_binding(api)
             )

    assert [{{:pull_review, "octo/example", 42, 9_100}, body}] =
             FakeAPI.state(api).updates

    assert body =~ "Denied in Emisar"
    assert body =~ "GitHub cannot approve this action"
    assert body =~ Publisher.marker(request.ref)

    assert Publisher.update_message(
             request,
             "github:issue_comment:9001",
             document,
             publisher_binding(api)
           ) == {:error, {:invalid_github_delivery, :message_ref}}
  end

  defp publisher_binding(api) do
    %{
      bindings: %{
        "github-main" => %{
          api: FakeAPI,
          client: api,
          repository_full_name: "octo/example",
          repository_id: 99
        }
      }
    }
  end

  defp message_request(thread_ref, message \\ "Done.") do
    assert {:ok, request} =
             Request.new(%{
               conversation_ref: "github:github-main:repository:99",
               document: %{"message" => message},
               kind: :message,
               ref: "delivery:github:#{thread_ref}",
               source_item_ref: nil,
               thread_ref: thread_ref,
               transport: "github"
             })

    request
  end

  defp reaction_request(kind, id, emoji_name) do
    assert {:ok, request} =
             Request.new(%{
               conversation_ref: "github:github-main:repository:99",
               document: %{"emoji_name" => emoji_name},
               kind: :reaction,
               ref: "reaction:github:#{kind}:#{id}",
               source_item_ref: "github:#{kind}:#{id}",
               thread_ref: "github:github-main:pull:42",
               transport: "github"
             })

    request
  end

  defp approval_status(status) do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-1",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => nil,
      "request_id" => "apr-1",
      "run_id" => "run-1",
      "run_url" => "https://emisar.example/app/acme/runs/run-1",
      "runner_ref" => "production-runner",
      "status" => status
    }
  end
end
