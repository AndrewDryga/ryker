defmodule Ryker.Publication.RequestTest do
  use ExUnit.Case, async: true
  alias Ryker.Publication.Request

  @repositories %{"ryker" => %{base_branch: "main", branch_prefix: "ryker"}}

  # The description was joined into one line, so a task's lists, code blocks
  # and paragraphs reached the pull request as one run-on paragraph
  # (2026-10-04 review).
  test "a pull request description keeps its lines, and its title stays one line" do
    request =
      request(%{
        body:
          "Fixes the retry.\r\n\n- keeps the lease\n- logs once\n\n```\nmix test\n```\nThanks @octo",
        title: "Fix the\nretry"
      })

    assert {:ok, body} = Request.worker_body(request, @repositories)

    assert body["body"] =~
             "Fixes the retry.\n\n- keeps the lease\n- logs once\n\n```\nmix test\n```\n" <>
               "Thanks @​octo"

    assert body["title"] == "Fix the retry"
  end

  # Draft PR AndrewDryga/test#10 opened with "## Ryker task" over the chat
  # reply and a "## Publication proof" list of the Coop session, trees and
  # commits, the first thing a reviewer read (Slack as Andrew, 2026-10-09).
  # The description is the change; how Ryker checked it is folded away.
  test "a pull request description leads with the change and folds Ryker's review away" do
    request = request(%{body: "Adds a short contributing guide.", title: "Add a guide"})

    assert {:ok, %{"body" => body}} = Request.worker_body(request, @repositories)

    assert String.starts_with?(body, "Adds a short contributing guide.")
    refute body =~ "## Ryker task"
    refute body =~ "## Publication proof"
    assert body =~ "<details>\n<summary>How Ryker checked this change</summary>"
    assert body =~ "- Reviewed tree: `#{request.review["candidate_tree"]}`"
    assert String.ends_with?(body, "</details>")
  end

  # GitHub keeps the branch name on a merged or closed pull request, and Coop
  # will not open a draft from a branch whose pull request ended. A later
  # generation that opens a new draft takes a branch of its own; one that
  # updates its open draft keeps that draft's branch.
  test "a new draft's branch names its generation, and an open draft keeps its own" do
    first = request(%{title: "Fix the retry", recovery_generation: 1})
    assert {:ok, %{"branch" => first_branch}} = Request.worker_body(first, @repositories)
    assert first_branch == "ryker/fix-the-retry-quest-test"

    later = %{first | recovery_generation: 3}

    assert {:ok, %{"branch" => "ryker/fix-the-retry-quest-test-3"}} =
             Request.worker_body(later, @repositories)

    open = %{
      later
      | existing_pull_request: %{
          "head_commit" => String.duplicate("c", 40),
          "number" => 7,
          "ref" => "refs/heads/ryker/fix-the-retry-quest-test",
          "url" => "https://github.com/acme/ryker/pull/7"
        }
    }

    assert {:ok, %{"branch" => "ryker/fix-the-retry-quest-test", "pull_request_number" => 7}} =
             Request.worker_body(open, @repositories)
  end

  defp request(fields) do
    struct!(
      Request,
      Map.merge(
        %{
          approval_ref: "approval:request-test",
          approved_at: ~U[2026-10-04 12:00:00Z],
          approved_by_actor_ref: "slack:T123:U123",
          body: "",
          existing_pull_request: nil,
          publication_ref: "publication:request-test",
          recovery_generation: 1,
          repository: "ryker",
          review: %{
            "candidate_head" => String.duplicate("a", 40),
            "candidate_tree" => String.duplicate("b", 40)
          },
          title: ""
        },
        fields
      )
    )
  end
end
