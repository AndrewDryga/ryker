defmodule Ryker.Operator.EpisodeReviewChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.Operator.EpisodeReview

  @fields [:actor_ref, :episode_id, :id, :note, :rating, :reviewed_at, :semantic_version]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %EpisodeReview{}
    |> cast(attributes, @fields)
    |> validate_required(@fields -- [:note])
    |> validate_length(:actor_ref, min: 1, max: 1_024)
    |> validate_length(:note, max: 2_048, count: :bytes)
    |> validate_number(:semantic_version, greater_than_or_equal_to: 0)
    |> unique_constraint([:episode_id, :semantic_version])
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:semantic_version, name: :episode_operator_review_valid)
  end
end
