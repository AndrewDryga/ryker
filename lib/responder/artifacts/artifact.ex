defmodule Responder.Artifacts.Artifact do
  @moduledoc """
  One immutable, authenticated input attachment stored outside model-visible
  platform metadata.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "input_artifacts" do
    field(:ref, :string)
    field(:source_kind, :string)
    field(:source_ref, :string)
    field(:name, :string)
    field(:media_type, :string)
    field(:sha256, :string)
    field(:byte_size, :integer)
    field(:data, :binary)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          ref: String.t() | nil,
          source_kind: String.t() | nil,
          source_ref: String.t() | nil,
          name: String.t() | nil,
          media_type: String.t() | nil,
          sha256: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          data: binary() | nil
        }
end
