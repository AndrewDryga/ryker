defmodule Ryker.Publication.CardTest do
  use ExUnit.Case, async: true

  alias Ryker.Publication.Card

  @review %{
    "candidate_tree" => String.duplicate("b", 40),
    "draft_authorized" => false,
    "gate" => "passed",
    "policy_findings" => [],
    "publishable" => true,
    "reasons" => [],
    "rebase" => "clean",
    "repository" => "ryker",
    "title" => "Fix retries"
  }

  # Review cards carried the size and digest of the patch a worker sent until
  # 2026-09-27, and reading one dropped them "so old delivered cards stay
  # readable": a second shape kept for good. No card stored since then carries
  # them, and the local instance held none (2026-10-05).
  test "a review card holds exactly its own fields" do
    card = %{
      "kind" => "publication_review",
      "payload" => @review,
      "ref" => "publication:card-fields",
      "status" => "open"
    }

    assert Card.prepare_record(card) == {:ok, @review}

    patched = put_in(card, ["payload", "patch_bytes"], 120)
    assert Card.prepare_record(patched) == {:error, {:invalid_publication_card, :review}}
  end
end
