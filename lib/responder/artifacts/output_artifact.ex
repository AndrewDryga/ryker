defmodule Responder.Artifacts.OutputArtifact do
  @moduledoc """
  One content-verified image retained from an accepted Coop turn.

  The opaque reference is scoped to its Work turn. Raw bytes never come from
  model JSON and cannot select a platform destination.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "work_output_artifacts" do
    belongs_to(:turn, Responder.Work.Turn)
    field(:ref, :string)
    field(:name, :string)
    field(:media_type, :string)
    field(:sha256, :string)
    field(:byte_size, :integer)
    field(:data, :binary)

    timestamps(type: :utc_datetime_usec)
  end
end
