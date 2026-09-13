defmodule Ryker.Artifacts.WorkReference do
  @moduledoc false

  use Ecto.Schema

  alias Ryker.Artifacts.Artifact
  alias Ryker.Work.Turn

  @primary_key false
  schema "work_input_artifact_references" do
    belongs_to(:turn, Turn, type: :binary_id, primary_key: true)
    belongs_to(:artifact, Artifact, type: :binary_id, primary_key: true)

    timestamps(type: :utc_datetime_usec)
  end
end
