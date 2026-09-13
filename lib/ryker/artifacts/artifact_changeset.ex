defmodule Ryker.Artifacts.ArtifactChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.Artifacts.Artifact

  @fields [:byte_size, :data, :id, :media_type, :name, :ref, :sha256, :source_kind, :source_ref]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %Artifact{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_length(:ref, min: 1, max: 128)
    |> validate_length(:source_kind, min: 1, max: 64)
    |> validate_length(:source_ref, min: 1, max: 1_024)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: 8 * 1_024 * 1_024)
    |> unique_constraint(:ref)
    |> unique_constraint([:source_kind, :source_ref])
    |> check_constraint(:data, name: :input_artifact_identity_valid)
  end
end
