defmodule Ryker.Publication.ReceiptTest do
  use ExUnit.Case, async: true
  alias Ryker.Publication.Receipt

  test "a successful push keeps the PR observation warning and cannot name another target" do
    target = Ryker.Fixtures.GitHubActions.publication_target()

    review = %{
      "candidate_tree" => String.duplicate("b", 40),
      "candidate_head" => String.duplicate("c", 40)
    }

    observation = %{
      "state" => "changed_after_push",
      "head_ref" => "human/fix",
      "base_ref" => "release",
      "head_repository_id" => 17,
      "base_repository_id" => 17,
      "head_commit" => review["candidate_head"],
      "pull_request_state" => "open"
    }

    receipt = %{
      "repository" => "ryker",
      "candidate_tree" => review["candidate_tree"],
      "commit_sha" => review["candidate_head"],
      "branch_ref" => target["head_ref"],
      "pull_request_number" => 7,
      "pull_request_url" => "https://github.com/example/repository/pull/7",
      "target_observation" => observation
    }

    assert {:ok, ^receipt} = Receipt.prepare(receipt, review, "ryker", target)
    assert {:error, _} = Receipt.prepare(receipt, review, "ryker")

    assert {:error, _} =
             Receipt.prepare(
               %{receipt | "branch_ref" => "refs/heads/other"},
               review,
               "ryker",
               target
             )

    assert {:error, _} =
             Receipt.prepare(
               put_in(receipt, ["target_observation", "state"], "made_up"),
               review,
               "ryker",
               target
             )
  end
end
