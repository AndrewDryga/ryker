defmodule Ryker.Operator.EpisodeReview.Query do
  @moduledoc "People's reviews of finished requests, for every read of `episode_operator_reviews`."
  use Ryker, :query
  alias Ryker.Operator.EpisodeReview

  def all, do: from(reviews in EpisodeReview, as: :episode_operator_reviews)

  @doc "The review of `episode_id` at its `semantic_version`."
  def by_version(episode_id, semantic_version) do
    where(
      all(),
      [episode_operator_reviews: r],
      r.episode_id == ^episode_id and r.semantic_version == ^semantic_version
    )
  end
end
