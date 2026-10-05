defmodule Ryker.Feedback.FeedbackReviewsAreRatingsMigrationTest do
  # The migrator runs inside this test's sandbox transaction, so nothing else
  # may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL

  @version 20_261_005_180_000
  @migration Ryker.Repo.Migrations.FeedbackReviewsAreRatings
  @file_name "20261005180000_feedback_reviews_are_ratings.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @reviews ~r/WHEN 'reviewed'::text THEN \(value = ANY \(ARRAY\[([^\]]*)\]/

  # Reviews of how a request ended stopped on 2026-09-29, when reviews became ratings, yet the
  # table, the signal and the Feedback page kept a value set and a category only they could
  # fill (2026-10-04 review).
  test "a feedback review is a rating, and rolling back accepts an ending again" do
    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    assert "reviewed" in allowed(~r/category = ANY \(ARRAY\[([^\]]*)\]/)
    assert allowed(@reviews) == ~w(complete cancelled good needs_work)

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)
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

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration do
    unless Code.ensure_loaded?(@migration) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", @file_name))
      |> Code.compile_file()
    end

    @migration
  end
end
