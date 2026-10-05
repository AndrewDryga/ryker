defmodule Ryker.Feedback.FeedbackReviewsAreRatingsMigrationTest do
  use Ryker.MigrationCase

  alias Ecto.Adapters.SQL

  @version 20_261_005_180_000
  @reviews ~r/WHEN 'reviewed'::text THEN \(value = ANY \(ARRAY\[([^\]]*)\]/

  # Reviews of how a request ended stopped on 2026-09-29, when reviews became ratings, yet the
  # table, the signal and the Feedback page kept a value set and a category only they could
  # fill (2026-10-04 review).
  test "a feedback review is a rating, and rolling back accepts an ending again" do
    assert :ok = migrate_down(@version)
    assert "reviewed" in allowed(~r/category = ANY \(ARRAY\[([^\]]*)\]/)
    assert allowed(@reviews) == ~w(complete cancelled good needs_work)

    assert :ok = migrate_up(@version)
    refute "reviewed" in allowed(~r/category = ANY \(ARRAY\[([^\]]*)\]/)
    assert allowed(@reviews) == ~w(good needs_work)
  end

  # The values the table's check allows in one of its lists.
  defp allowed(list) do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'answer_feedback_valid'",
        []
      )

    [values] = Regex.run(list, definition, capture: :all_but_first)
    for [value] <- Regex.scan(~r/'([a-z_]+)'::text/, values, capture: :all_but_first), do: value
  end
end
