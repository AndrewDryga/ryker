defmodule Ryker.Artifacts.OutputArtifact do
  @moduledoc """
  One content-verified image retained from an accepted Coop turn.

  The opaque reference is scoped to its Work turn. Raw bytes never come from
  model JSON and cannot select a platform destination.
  """
  use Ryker, :schema

  schema "work_output_artifacts" do
    belongs_to(:turn, Ryker.Work.Turn)
    field(:ref, :string)
    field(:name, :string)
    field(:media_type, :string)
    field(:sha256, :string)
    field(:byte_size, :integer)
    field(:data, :binary)

    timestamps()
  end

  @type t :: %__MODULE__{}
end
