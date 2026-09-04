defmodule Responder.GitHub.InputTest do
  use ExUnit.Case, async: true

  alias Responder.GitHub.{Binding, Input}
  alias Responder.Ingress.Input, as: IngressInput

  test "declares GitHub as its generic ingress source kind" do
    assert Input.source_kind() == "github"
  end

  test "a pull request comment becomes one canonical input with a trusted repository target" do
    payload = issue_comment_payload()
    payload = put_in(payload, ["destination"], %{"conversation_ref" => "attacker"})

    assert {:ok, input} = normalize("issue_comment", payload)

    assert input.source == %{kind: "github", ref: "github-main"}
    assert input.actor == %{kind: :user, ref: "github-user:7"}
    assert input.event_kind == :message
    assert input.event_ref == "github-body:#{String.duplicate("a", 64)}"
    assert input.native_input_id =~ "github-item:"
    assert input.occurred_at == ~U[2026-08-28 12:00:00.000000Z]
    assert input.occurred_at_source == :source
    assert input.revision == 5_363_755_200_000_000
    assert input.source_item_ref == "github:issue_comment:9001"

    assert input.destination == %{
             conversation_ref: "github:github-main:repository:99",
             thread_ref: "github:github-main:pull:42",
             transport: "github"
           }

    assert input.source_capabilities == %{
             "react" => %{
               "emoji_names" => ~w(+1 -1 confused eyes heart hooray laugh rocket)
             }
           }

    assert IngressInput.reaction_names(input) ==
             ~w(+1 -1 confused eyes heart hooray laugh rocket)

    assert input.content["payload"]["destination"]["conversation_ref"] == "attacker"
    refute input.destination.conversation_ref == "attacker"
  end

  test "edits and deletes keep stable item identity while advancing source revision" do
    created = issue_comment_payload()

    edited =
      created
      |> put_in(["action"], "edited")
      |> put_in(["comment", "updated_at"], "2026-08-28T12:01:00Z")
      |> put_in(["comment", "body"], "Edited guidance")

    deleted =
      edited
      |> put_in(["action"], "deleted")
      |> put_in(["comment", "updated_at"], "2026-08-28T12:02:00Z")

    assert {:ok, first} = normalize("issue_comment", created, "delivery-create")
    assert {:ok, second} = normalize("issue_comment", edited, "delivery-edit")
    assert {:ok, third} = normalize("issue_comment", deleted, "delivery-delete")

    assert first.native_input_id == second.native_input_id
    assert second.native_input_id == third.native_input_id
    assert [first.event_kind, second.event_kind, third.event_kind] == [:message, :edit, :delete]
    assert first.revision < second.revision
    assert second.revision < third.revision
    assert third.source_capabilities == %{}
    refute :react in IngressInput.allowed_actions(third)
  end

  test "review bodies and inline review threads preserve their distinct GitHub identities" do
    assert {:ok, review} = normalize("pull_request_review", review_payload())

    assert review.event_kind == :message
    assert review.source_item_ref == "github:pull_request_review:7001"
    assert review.destination.thread_ref == "github:github-main:pull:42"
    assert review.source_capabilities == %{}

    assert {:ok, comment} =
             normalize("pull_request_review_comment", review_comment_payload())

    assert comment.source_item_ref == "github:pull_request_review_comment:8002"

    assert comment.destination.thread_ref ==
             "github:github-main:pull:42:review-thread:8001"

    assert :react in IngressInput.allowed_actions(comment)
  end

  test "issue and pull request lifecycle events retain stable subject identity across revisions" do
    issue = issue_lifecycle_payload("opened", "2026-08-28T12:00:00Z")
    edited_issue = issue_lifecycle_payload("edited", "2026-08-28T12:01:00Z")
    closed_issue = issue_lifecycle_payload("closed", "2026-08-28T12:02:00Z")

    assert {:ok, opened} = normalize("issues", issue, "issue-opened")
    assert {:ok, edited} = normalize("issues", edited_issue, "issue-edited")
    assert {:ok, closed} = normalize("issues", closed_issue, "issue-closed")

    assert opened.event_kind == :event
    assert opened.source_item_ref == "github:issue:4200"
    assert opened.destination.thread_ref == "github:github-main:issue:42"
    assert opened.native_input_id == edited.native_input_id
    assert edited.native_input_id == closed.native_input_id
    assert opened.revision < edited.revision
    assert edited.revision < closed.revision
    assert opened.source_capabilities == %{}

    pull = pull_lifecycle_payload("opened", "2026-08-28T12:00:00Z")
    synchronized = pull_lifecycle_payload("synchronize", "2026-08-28T12:01:00Z")

    assert {:ok, first} = normalize("pull_request", pull, "pull-opened")
    assert {:ok, second} = normalize("pull_request", synchronized, "pull-synchronized")
    assert first.source_item_ref == "github:pull_request:4300"
    assert first.destination.thread_ref == "github:github-main:pull:43"
    assert first.native_input_id == second.native_input_id
    assert first.revision < second.revision
  end

  test "the adapter rejects unsupported actions and payload-selected installation or repository" do
    assert {:error, {:invalid_github_input, :event}} =
             normalize("push", issue_comment_payload())

    assert {:error, {:invalid_github_input, :action}} =
             normalize("issue_comment", put_in(issue_comment_payload(), ["action"], "pinned"))

    assert {:error, {:invalid_github_input, :installation}} =
             normalize(
               "issue_comment",
               put_in(issue_comment_payload(), ["installation", "id"], 1234)
             )

    assert {:error, {:invalid_github_input, :repository}} =
             normalize(
               "issue_comment",
               put_in(issue_comment_payload(), ["repository", "id"], 1234)
             )
  end

  test "the trusted binding suppresses self events and rejects unlisted GitHub actors" do
    self_authored =
      issue_comment_payload()
      |> put_in(["sender"], %{"id" => 99, "login" => "responder[bot]", "type" => "Bot"})

    assert {:error, {:github_input_ignored, :self_authored}} =
             normalize("issue_comment", self_authored)

    unauthorized =
      issue_comment_payload()
      |> put_in(["sender"], %{"id" => 10, "login" => "outsider", "type" => "User"})

    assert {:error, {:github_input_ignored, :actor_not_authorized}} =
             normalize("issue_comment", unauthorized)

    authorized_bot =
      issue_comment_payload()
      |> put_in(["sender"], %{"id" => 8, "login" => "trusted[bot]", "type" => "Bot"})

    assert {:ok, input} = normalize("issue_comment", authorized_bot)
    assert input.actor == %{kind: :bot, ref: "github-user:8"}
  end

  defp normalize(event_name, payload, delivery_ref \\ "delivery-123") do
    Input.normalize(
      %{
        delivery_ref: delivery_ref,
        event_name: event_name,
        event_ref: "github-body:#{String.duplicate("a", 64)}",
        payload: payload
      },
      binding!()
    )
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
               secret: String.duplicate("s", 32)
             })

    binding
  end

  defp issue_comment_payload do
    %{
      "action" => "created",
      "comment" => %{
        "body" => "Please update the implementation.",
        "created_at" => "2026-08-28T12:00:00Z",
        "id" => 9001,
        "node_id" => "IC_kwDOExample",
        "updated_at" => "2026-08-28T12:00:00Z",
        "user" => %{"id" => 7, "login" => "octocat", "type" => "User"}
      },
      "installation" => %{"id" => 41},
      "issue" => %{
        "number" => 42,
        "pull_request" => %{"url" => "https://api.github.test/repos/octo/example/pulls/42"},
        "title" => "Make ingress generic"
      },
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end

  defp review_payload do
    %{
      "action" => "submitted",
      "installation" => %{"id" => 41},
      "pull_request" => %{"number" => 42, "title" => "Make ingress generic"},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "review" => %{
        "body" => "One concern remains.",
        "id" => 7001,
        "node_id" => "PRR_kwDOExample",
        "state" => "commented",
        "submitted_at" => "2026-08-28T12:00:00Z",
        "user" => %{"id" => 7, "login" => "octocat", "type" => "User"}
      },
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end

  defp review_comment_payload do
    %{
      "action" => "created",
      "comment" => %{
        "body" => "This should be fenced.",
        "created_at" => "2026-08-28T12:00:00Z",
        "id" => 8002,
        "in_reply_to_id" => 8001,
        "node_id" => "PRRC_kwDOExample",
        "updated_at" => "2026-08-28T12:00:00Z",
        "user" => %{"id" => 7, "login" => "octocat", "type" => "User"}
      },
      "installation" => %{"id" => 41},
      "pull_request" => %{"number" => 42, "title" => "Make ingress generic"},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end

  defp issue_lifecycle_payload(action, updated_at) do
    %{
      "action" => action,
      "installation" => %{"id" => 41},
      "issue" => %{
        "body" => "Lifecycle body",
        "created_at" => "2026-08-28T12:00:00Z",
        "id" => 4_200,
        "number" => 42,
        "title" => "Lifecycle issue",
        "updated_at" => updated_at,
        "user" => %{"id" => 7, "login" => "octocat", "type" => "User"}
      },
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end

  defp pull_lifecycle_payload(action, updated_at) do
    %{
      "action" => action,
      "installation" => %{"id" => 41},
      "pull_request" => %{
        "body" => "Lifecycle body",
        "created_at" => "2026-08-28T12:00:00Z",
        "head" => %{"sha" => String.duplicate("a", 40)},
        "id" => 4_300,
        "number" => 43,
        "title" => "Lifecycle pull request",
        "updated_at" => updated_at,
        "user" => %{"id" => 7, "login" => "octocat", "type" => "User"}
      },
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
  end
end
