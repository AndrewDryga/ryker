defmodule Ryker.Operator.EpisodeReview do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_operator_reviews" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    field(:semantic_version, :integer)
    field(:actor_ref, :string)
    field(:note, :string, default: "")
    field(:reviewed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
