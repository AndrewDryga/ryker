defmodule Ryker.Operator.EpisodeReviews do
  @moduledoc """
  A person's rating of how one exact ending of a request went: good, or
  needs work. Append-only, one per terminal episode version.

  Andrew, 2026-09-28, of the "Mark how this request ended as reviewed"
  this replaced: "i just mark it so what next? this is half baked!" A rating
  is kept as feedback on the request (`Ryker.Feedback`) in the same
  transaction, and "needs work" makes the request a candidate for Ryker's
  self-analysis (`Ryker.Improvement`), which works out what went wrong.

  A later semantic ending is rateable again. The same rating given again
  returns the existing receipt; a different one for the same ending is
  refused rather than rewriting who rated it and how. A rating recorded is
  announced after the outermost commit (`subscribe_reviews/0`), on the
  request's topics too.
  """
  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Operator.EpisodeReview
  alias Ryker.Reference
  alias Ryker.Repo
  require Logger

  @ratings [:good, :needs_work]

  @spec review(String.t(), String.t(), :good | :needs_work, String.t()) ::
          {:ok, %{review: EpisodeReview.t(), status: :recorded | :duplicate}} | {:error, term()}
  def review(episode_key, actor_ref, rating, note \\ "") do
    with :ok <- reference(episode_key, :episode_key),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- rating(rating),
         :ok <- note(note) do
      Repo.transaction(fn -> review_locked(episode_key, actor_ref, rating, note) end)
    end
  end

  defp review_locked(episode_key, actor_ref, rating, note) do
    episode =
      episode_key
      |> Episodes.Episode.Query.by_key()
      |> Episodes.Episode.Query.lock_for_update()
      |> Repo.one() ||
        Repo.rollback(:episode_not_found)

    if episode.state not in [:complete, :cancelled], do: Repo.rollback(:episode_not_reviewable)

    case Repo.fetch(EpisodeReview.Query.by_version(episode.id, episode.semantic_version)) do
      {:ok, %EpisodeReview{actor_ref: ^actor_ref, rating: ^rating, note: ^note} = review} ->
        %{review: review, status: :duplicate}

      {:ok, %EpisodeReview{}} ->
        Repo.rollback(:episode_review_conflict)

      {:error, :not_found} ->
        attributes = %{
          actor_ref: actor_ref,
          episode_id: episode.id,
          id: Repo.generate_id(),
          note: note,
          rating: rating,
          reviewed_at: Repo.now!(),
          semantic_version: episode.semantic_version
        }

        changeset = EpisodeReview.Changeset.insert(attributes)

        case Repo.insert(changeset) do
          {:ok, review} ->
            broadcast_review_recorded(review)
            record_feedback(review, episode)
            %{review: review, status: :recorded}

          {:error, changeset} ->
            Repo.rollback({:episode_review_store, changeset.errors})
        end
    end
  end

  # The rating is the act; the feedback is what it says about the answer.
  # A signal that cannot be kept is logged and never undoes the rating.
  defp record_feedback(%EpisodeReview{} = review, %Episodes.Episode{} = episode) do
    case Feedback.record_in_transaction(%{
           kind: :reviewed,
           value: Atom.to_string(review.rating),
           note: if(review.note == "", do: nil, else: review.note),
           actor_ref: review.actor_ref,
           source: "control_plane",
           source_ref: "episode-review:#{review.id}",
           occurred_at: review.reviewed_at,
           request: {:episode, episode.id}
         }) do
      {:ok, _recorded} ->
        :ok

      {:error, reason} ->
        Logger.warning("review feedback not kept: #{inspect(reason, limit: 5)}")
        :ok
    end
  end

  defp reference(value, field), do: Reference.check(value, field, :invalid_episode_review)

  defp rating(rating) when rating in @ratings, do: :ok
  defp rating(_rating), do: {:error, {:invalid_episode_review, :rating}}

  defp note(value) when is_binary(value) and byte_size(value) <= 2_048 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, {:invalid_episode_review, :note}}
  end

  defp note(_value), do: {:error, {:invalid_episode_review, :note}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to request ratings: `{:episode_reviewed, review_id}`
  once a person rates how a finished request went, and that change has
  committed.
  """
  def subscribe_reviews, do: Ryker.PubSub.subscribe(reviews_topic())

  def unsubscribe_reviews, do: Ryker.PubSub.unsubscribe(reviews_topic())

  defp reviews_topic, do: "operator:reviews"

  defp broadcast_review_recorded(%EpisodeReview{id: id, episode_id: episode_id}) do
    Ryker.Episodes.broadcast_episode_updated(episode_id)
    Repo.after_commit(fn -> Ryker.PubSub.broadcast(reviews_topic(), {:episode_reviewed, id}) end)
  end
end
