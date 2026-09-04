defmodule Responder.Operator.EpisodeReviewsTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Operator.EpisodeReviews

  @now ~U[2026-09-04 12:00:00.000000Z]

  test "review inputs and missing episodes fail before any audit record is written" do
    assert EpisodeReviews.review(nil, "control-plane:local") ==
             {:error, {:invalid_episode_review, :episode_key}}

    assert EpisodeReviews.review("episode", nil) ==
             {:error, {:invalid_episode_review, :actor_ref}}

    assert EpisodeReviews.review("episode", "control-plane:local", nil) ==
             {:error, {:invalid_episode_review, :note}}

    assert EpisodeReviews.review(<<255>>, "control-plane:local") ==
             {:error, :invalid_episode_review}

    assert EpisodeReviews.review("missing:episode", "control-plane:local") ==
             {:error, :episode_not_found}
  end

  test "review acknowledgement belongs to one exact terminal semantic version" do
    episode_id = Ecto.UUID.generate()
    episode_key = "review:#{episode_id}"
    turn_ref = "turn:#{episode_id}"

    assert {:ok, started} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: episode_key,
                 native_input_id: "input:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: turn_ref
               })
             )

    assert EpisodeReviews.review(episode_key, "control-plane:local") ==
             {:error, :episode_not_reviewable}

    assert {:ok, cancelled} =
             Episodes.apply(%Command.CancelEpisode{
               cancel_ref: "cancel:#{episode_id}",
               episode_key: episode_key,
               expected_owner: %{kind: :turn, ref: turn_ref},
               occurred_at: DateTime.add(@now, 1, :second),
               reason: "No longer needed"
             })

    assert cancelled.episode.state == :cancelled

    assert {:ok, %{review: review, status: :recorded}} =
             EpisodeReviews.review(episode_key, "control-plane:local")

    assert review.episode_id == started.episode.id
    assert review.semantic_version == cancelled.episode.semantic_version

    assert {:ok, %{review: replayed, status: :duplicate}} =
             EpisodeReviews.review(episode_key, "control-plane:local")

    assert replayed.id == review.id

    assert EpisodeReviews.review(episode_key, "another-operator") ==
             {:error, :episode_review_conflict}
  end
end
