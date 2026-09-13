defmodule Ryker.Artifacts.OutputArtifactChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.Artifacts.OutputArtifact

  @fields [:byte_size, :data, :id, :media_type, :name, :ref, :sha256, :turn_id]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %OutputArtifact{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_format(:ref, ~r/\A[A-Za-z0-9_.:-]{1,256}\z/)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:media_type, ~w(image/png image/jpeg image/webp image/gif))
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: 8 * 1_024 * 1_024)
    |> foreign_key_constraint(:turn_id)
    |> unique_constraint([:turn_id, :ref])
    |> unique_constraint([:turn_id, :sha256])
    |> check_constraint(:data, name: :work_output_artifact_identity_valid)
  end
end
