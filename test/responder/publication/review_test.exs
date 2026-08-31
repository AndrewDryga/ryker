defmodule Responder.Publication.ReviewTest do
  use ExUnit.Case, async: true

  alias Responder.Publication.Review

  test "malformed pull request identities fail closed without raising" do
    expected = %{revision: 7, session_id: "session-review"}

    for head <- [nil, %{}, 42, "not-a-commit"] do
      document = put_in(review_document(), ["pull_request", "head_commit"], head)

      assert Review.prepare(document, expected) ==
               {:error, {:invalid_publication_review, :pull_request}}
    end
  end

  defp review_document do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "operation-review",
      "parent_head" => String.duplicate("4", 40),
      "parent_tree" => String.duplicate("5", 40),
      "patch_artifact_id" => "patch-review",
      "patch_bytes" => 1,
      "patch_digest" => String.duplicate("8", 64),
      "patch_truncated" => false,
      "policy_digest" => String.duplicate("a", 64),
      "policy_findings" => [],
      "publishable" => true,
      "pull_request" => %{
        "head_commit" => String.duplicate("9", 40),
        "number" => 42,
        "ref" => "refs/heads/responder/fix"
      },
      "rebase" => "clean",
      "session_id" => "session-review",
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end
end
