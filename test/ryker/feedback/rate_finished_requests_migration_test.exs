defmodule Ryker.Feedback.RateFinishedRequestsMigrationTest do
  @moduledoc """
  Andrew, 2026-09-28, of "Mark how this request ended as reviewed?": "i just
  mark it so what next? this is half baked!" A person now rates how a finished
  request went, good or needs work. The migration lets a review keep its
  rating and its feedback signal carry it, and keeps every review recorded
  before ratings as it was.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @previous_version 20_260_928_210_000
  @version 20_260_929_000_000
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @at ~N[2026-09-28 09:00:00.000000]

  test "a rating is kept beside the reviews from before it, and rolling back refuses while one exists" do
    repo = start_migration_repo!()
    prefix = "rate_finished_requests_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      migrate!(repo, prefix, @previous_version)
      episode = episode!(repo, prefix)
      reviewed = review!(repo, prefix, episode, 1, nil)
      ended = feedback!(repo, prefix, episode, "complete", "reviewed", "episode-review:before")

      assert_raise Postgrex.Error, ~r/answer_feedback_valid/, fn ->
        feedback!(repo, prefix, episode, "needs_work", "frustrated", "episode-review:early")
      end

      assert @version in migrate!(repo, prefix, @version)

      rated = review!(repo, prefix, episode, 2, "needs_work")

      needs_work =
        feedback!(repo, prefix, episode, "needs_work", "frustrated", "episode-review:r")

      assert_raise Postgrex.Error, ~r/episode_operator_review_rating_valid/, fn ->
        review!(repo, prefix, episode, 3, "meh")
      end

      assert_raise Postgrex.Error, ~r/answer_feedback_valid/, fn ->
        feedback!(repo, prefix, episode, "meh", "frustrated", "episode-review:meh")
      end

      assert ratings(repo, prefix) == %{reviewed => nil, rated => "needs_work"}

      assert_raise Postgrex.Error, ~r/requests rated good or needs work are kept/, fn ->
        down!(repo, prefix)
      end

      SQL.query!(repo, "DELETE FROM #{prefix}.answer_feedback WHERE id = $1", [
        Ecto.UUID.dump!(needs_work)
      ])

      SQL.query!(repo, "DELETE FROM #{prefix}.episode_operator_reviews WHERE id = $1", [
        Ecto.UUID.dump!(rated)
      ])

      assert down!(repo, prefix) == [@version]

      # The reviews from before ratings survive both ways.
      assert ids(repo, prefix, "episode_operator_reviews") == [reviewed]
      assert ids(repo, prefix, "answer_feedback") == [ended]
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp episode!(repo, prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_kernel_episodes
        (id, key, state, destination_transport, destination_conversation_ref,
         inserted_at, updated_at)
      VALUES ($1, $2, 'complete', 'slack', 'T1:C1', $3, $3)
      """,
      [Ecto.UUID.dump!(id), "episode:#{id}", @at]
    )

    id
  end

  defp review!(repo, prefix, episode_id, version, nil) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_operator_reviews
        (id, episode_id, semantic_version, actor_ref, note, reviewed_at, inserted_at)
      VALUES ($1, $2, $3, 'control-plane:local', '', $4, $4)
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(episode_id), version, @at]
    )

    id
  end

  defp review!(repo, prefix, episode_id, version, rating) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_operator_reviews
        (id, episode_id, semantic_version, actor_ref, note, rating, reviewed_at, inserted_at)
      VALUES ($1, $2, $3, 'control-plane:local', '', $4, $5, $5)
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(episode_id), version, rating, @at]
    )

    id
  end

  defp feedback!(repo, prefix, episode_id, value, category, source_ref) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.answer_feedback
        (id, kind, value, category, actor_ref, source, source_ref, occurred_at, episode_id)
      VALUES ($1, 'reviewed', $2, $3, 'control-plane:local', 'control_plane', $4, $5, $6)
      """,
      [Ecto.UUID.dump!(id), value, category, source_ref, @at, Ecto.UUID.dump!(episode_id)]
    )

    id
  end

  defp ratings(repo, prefix) do
    %{rows: rows} =
      SQL.query!(repo, "SELECT id, rating FROM #{prefix}.episode_operator_reviews", [])

    Map.new(rows, fn [id, rating] -> {Ecto.UUID.load!(id), rating} end)
  end

  defp ids(repo, prefix, table) do
    %{rows: rows} = SQL.query!(repo, "SELECT id FROM #{prefix}.#{table}", [])
    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp migrate!(repo, prefix, version),
    do: Ecto.Migrator.run(repo, @migrations_path, :up, to: version, prefix: prefix, log: false)

  defp down!(repo, prefix),
    do: Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
