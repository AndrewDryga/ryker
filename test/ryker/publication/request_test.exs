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
