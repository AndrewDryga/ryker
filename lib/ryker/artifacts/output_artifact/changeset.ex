defmodule Ryker.Artifacts.OutputArtifact.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Artifacts.OutputArtifact
  alias Ryker.Crypto
  alias Ryker.Reference

  @fields [:byte_size, :data, :id, :media_type, :name, :ref, :sha256, :turn_id]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %OutputArtifact{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_format(:ref, Reference.token_pattern())
    |> validate_length(:name, min: 1, max: 255)
    # A media type is IANA's name, and it is sent on as it is written: an enum
    # would only translate it back.
    # credo:disable-for-next-line Ryker.Checks.EnumOverValidateInclusion
    |> validate_inclusion(:media_type, ~w(image/png image/jpeg image/webp image/gif))
    |> validate_format(:sha256, Crypto.sha256_hex_pattern())
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: 8 * 1_024 * 1_024)
    |> foreign_key_constraint(:turn_id)
    |> unique_constraint([:turn_id, :ref])
    |> unique_constraint([:turn_id, :sha256])
    |> check_constraint(:data, name: :work_output_artifact_identity_valid)
  end
end
