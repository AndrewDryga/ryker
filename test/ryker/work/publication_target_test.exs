defmodule Ryker.Work.PublicationTargetTest do
  use ExUnit.Case, async: true
  alias Ryker.Ingress
  alias Ryker.Work.PublicationTarget

  setup do
    head = String.duplicate("a", 40)

    entry = %Ingress.Inbox.Entry{
      id: Ecto.UUID.generate(),
      execution_mode: :live,
      source_kind: "github",
      source_ref: "widget-app",
      actor_kind: :user,
      actor_ref: "github-user:7",
      event_ref: "github-action:selection",
      source_item_ref: "github-action:selection",
      content: %{
        "event_name" => "ryker_action",
        "payload" => %{
          "action" => "fix_review",
          "sender" => %{"id" => 7, "login" => "ada", "type" => "User"},
          "repository" => %{"id" => 99},
          "installation" => %{"id" => 41}
        },
        "action_evidence" => %{
          "head" => head,
          "app_actor_id" => 30,
          "branch" => "fix-input",
          "base_branch" => "main",
          "pull_request_number" => 42,
          "findings" => Ryker.Fixtures.GitHubActions.publication_target()["findings"]
        }
      }
    }

    %{entry: entry, head: head}
  end

  test "the host pins the original actor and exact PR source despite a different model selector",
       %{entry: entry, head: head} do
    assert {:ok, target} = PublicationTarget.from_input(entry, "widget")
    assert target["authorization"] == %{"kind" => "github_user", "id" => 7, "login" => "ada"}
    assert target["head_ref"] == "refs/heads/fix-input"
    assert target["source_input_id"] == entry.id

    payload = %{
      "repository_source" => %{"kind" => "default"},
      "prompt" => "Fix the chosen findings."
    }

    pinned = PublicationTarget.pin_source(payload, target)
    assert pinned["repository_source"] == %{"kind" => "commit", "sha" => head}
    assert pinned["prompt"] == payload["prompt"]
  end

  test "a crossed actor, shadow input or ordinary webhook cannot mint action authority", %{
    entry: entry
  } do
    for changed <- [
          %{entry | actor_ref: "github-user:8"},
          %{entry | execution_mode: :shadow},
          %{entry | source_item_ref: "github:comment:12"}
        ] do
      assert PublicationTarget.from_input(changed, "widget") ==
               {:error, :invalid_publication_target}
    end

    ordinary = put_in(entry.content["event_name"], "issue_comment")
    assert PublicationTarget.from_input(ordinary, "widget") == {:ok, nil}
  end

  test "stored targets cannot acquire extra authority or symbolic heads", %{entry: entry} do
    assert {:ok, target} = PublicationTarget.from_input(entry, "widget")

    assert PublicationTarget.parse(Map.put(target, "merge", true)) ==
             {:error, :invalid_publication_target}

    assert PublicationTarget.parse(%{target | "head_commit" => "main"}) ==
             {:error, :invalid_publication_target}

    assert PublicationTarget.parse(%{target | "head_ref" => "refs/heads/main"}) ==
             {:error, :invalid_publication_target}
  end
end
