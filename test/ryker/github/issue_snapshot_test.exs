defmodule Ryker.GitHub.IssueSnapshotTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.IssueSnapshot

  @access %{
    repository: %{github_repository: "acme/widget"},
    settings: %{github: %{api_url: "https://api.github.com"}}
  }
  @issue %{
    "id" => 31,
    "number" => 12,
    "state" => "open",
    "title" => "Handle empty input",
    "body" => "Handle empty input.",
    "updated_at" => "2026-11-17T12:00:00Z"
  }

  test "a snapshot keeps the exact text and uses the host's canonical issue link" do
    assert {:ok, issue} =
             IssueSnapshot.prepare(
               @access,
               12,
               Map.put(@issue, "html_url", "https://another.example")
             )

    assert issue["body"] == @issue["body"]
    assert issue["url"] == "https://github.com/acme/widget/issues/12"
    refute Map.has_key?(issue, "state")
  end

  test "closed issues, PRs, crossed numbers and malformed or oversized data are refused" do
    for issue <- [
          Map.put(@issue, "state", "closed"),
          Map.put(@issue, "pull_request", %{}),
          Map.put(@issue, "number", 13),
          Map.put(@issue, "body", String.duplicate("x", 48_001)),
          Map.put(@issue, "updated_at", nil),
          Map.put(@issue, "title", "")
        ] do
      assert IssueSnapshot.prepare(@access, 12, issue) == {:error, :issue_unavailable}
    end

    assert {:error, _bounded} =
             IssueSnapshot.prepare(
               @access,
               12,
               Map.put(@issue, "body", String.duplicate("\u0001", 12_000))
             )
  end
end
