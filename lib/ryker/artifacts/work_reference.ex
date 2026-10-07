defmodule Ryker.Artifacts.WorkReference do
  @moduledoc false
  use Ryker, :schema
  alias Ryker.Artifacts.Artifact
  alias Ryker.Work.Turn

  @primary_key false
  schema "work_input_artifact_references" do
    belongs_to(:turn, Turn, type: :binary_id, primary_key: true)
    belongs_to(:artifact, Artifact, type: :binary_id, primary_key: true)

    timestamps()
  end
end
