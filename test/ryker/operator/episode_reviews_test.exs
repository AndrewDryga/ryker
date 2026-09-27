defmodule Ryker.Operator.EpisodeReviewsTest do
  use Ryker.DataCase, async: true

  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Feedback
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Operator.EpisodeReviews

  @now ~U[2026-09-04 12:00:00.000000Z]

  test "review inputs and missing episodes fail before any audit record is written" do
    assert EpisodeReviews.review(nil, "control-plane:local") ==
             {:error, {:invalid_episode_review, :episode_key}}

    assert EpisodeReviews.review("episode", nil) ==
             {:error, {:invalid_episode_review, :actor_ref}}

    assert EpisodeReviews.review("episode", "control-plane:local", nil) ==
             {:error, {:invalid_episode_review, :note}}

    # A malformed value names its field like a missing one does.
    assert EpisodeReviews.review(<<255>>, "control-plane:local") ==
             {:error, {:invalid_episode_review, :episode_key}}

    assert EpisodeReviews.review("missing:episode", "control-plane:local") ==
             {:error, :episode_not_found}
  end

  # Activity and a request's Timeline say whether a finished request was
  # reviewed. Until 2026-09-26 they heard of a review from a trigger's NOTIFY
  # and a five-second poll; the review is now announced, on the request's
  # topic too, once it commits.
  test "a recorded review reaches the reviewed request's pages" do
    episode_id = Ecto.UUID.generate()
    episode_key = "review-announced:#{episode_id}"
    turn_ref = "turn:#{episode_id}"

    assert {:ok, _started} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: episode_key,
                 native_input_id: "input:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _cancelled} =
             Episodes.apply(%Command.CancelEpisode{
               cancel_ref: "cancel:#{episode_id}",
               episode_key: episode_key,
               expected_owner: %{kind: :turn, ref: turn_ref},
               occurred_at: DateTime.add(@now, 1, :second),
               reason: "No longer needed"
             })

    :ok = EpisodeReviews.subscribe_reviews()
    :ok = Episodes.subscribe_episode(episode_id)

    assert {:ok, %{review: %{id: id}, status: :recorded}} =
             EpisodeReviews.review(episode_key, "control-plane:local")

    assert_received {:episode_reviewed, ^id}
    assert_received {:episode_updated, ^episode_id}
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

  # Andrew, 2026-09-27: the operator's review of how a request ended is one of
  # the signals the Feedback page groups, beside what people said about the
  # answer. It is kept with the request, with the ending it covered and the
  # note, in the same act as the review, and a replayed review adds nothing.
  test "marking how a request ended reviewed keeps it as feedback with the ending and its note" do
    episode_id = Ecto.UUID.generate()
    episode_key = "review-feedback:#{episode_id}"
    turn_ref = "turn:#{episode_id}"

    assert {:ok, _started} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: episode_key,
                 native_input_id: "input:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _cancelled} =
             Episodes.apply(%Command.CancelEpisode{
               cancel_ref: "cancel:#{episode_id}",
               episode_key: episode_key,
               expected_owner: %{kind: :turn, ref: turn_ref},
               occurred_at: DateTime.add(@now, 1, :second),
               reason: "No longer needed"
             })

    :ok = Feedback.subscribe_feedback()

    assert {:ok, %{review: review, status: :recorded}} =
             EpisodeReviews.review(episode_key, "control-plane:local", "Stopped on purpose.")

    assert [signal] = Feedback.for_request({:episode, episode_id})

    assert {signal.kind, signal.value, signal.note, signal.category} ==
             {:reviewed, "cancelled", "Stopped on purpose.", :reviewed}

    assert {signal.actor_ref, signal.source, signal.source_ref} ==
             {"control-plane:local", "control_plane", "episode-review:#{review.id}"}

    assert signal.occurred_at == review.reviewed_at
    signal_id = signal.id
    assert_received {:feedback_recorded, ^signal_id}

    assert {:ok, %{status: :duplicate}} =
             EpisodeReviews.review(episode_key, "control-plane:local", "Stopped on purpose.")

    assert [^signal] = Feedback.for_request({:episode, episode_id})
  end
end
