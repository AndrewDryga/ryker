defmodule Ryker.GitHub.SourceRefTest do
  use ExUnit.Case, async: true

  alias Ryker.GitHub.SourceRef

  test "round-trips only exact reaction-capable GitHub comment identities" do
    ref = SourceRef.item("github-main", "pull_request_review_comment", 8_002)

    assert ref == "github-source:v1:github-main:pull_request_review_comment:8002"

    assert SourceRef.parse(ref) ==
             {:ok,
              %{
                binding: "github-main",
                item_id: 8_002,
                item_kind: "pull_request_review_comment"
              }}

    assert SourceRef.parse("github-source:v1:github-main:pull_request_review:7001") ==
             {:error, :invalid_github_source_ref}

    assert_raise ArgumentError, fn -> SourceRef.item("bad binding", "issue_comment", 1) end
  end
end
