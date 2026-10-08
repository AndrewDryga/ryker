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

  # A task's title is accepted at up to 120 characters, as the offer and the
  # database count them, and its card measured the same title in bytes: a
  # title written in Ukrainian passed the offer and then left the review card
  # unreadable, so it was never shown (2026-10-08).
  test "a card's title is measured in characters, as the task's title was accepted" do
    title = String.duplicate("Виправити повтори", 6)
    assert Ryker.Text.char_length(title) <= 120 and byte_size(title) > 120

    card = %{
      "kind" => "publication_review",
      "payload" => %{@review | "title" => title},
      "ref" => "publication:card-title",
      "status" => "open"
    }

    assert Card.prepare_record(card) == {:ok, %{@review | "title" => title}}
  end
end
