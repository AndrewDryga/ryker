defmodule Ryker.Operator.EpisodeReview do
  @moduledoc false
  use Ryker, :schema

  schema "episode_operator_reviews" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    field(:semantic_version, :integer)
    field(:actor_ref, :string)
    field(:note, :string, default: "")
    # How the person rated it; nil on reviews recorded before ratings.
    field(:rating, Ecto.Enum, values: [:good, :needs_work])
    field(:reviewed_at, :utc_datetime_usec)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}
end
