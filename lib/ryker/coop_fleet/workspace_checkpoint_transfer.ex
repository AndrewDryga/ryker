defmodule Ryker.CoopFleet.WorkspaceCheckpointTransfer do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "coop_worker_workspace_checkpoints" do
    belongs_to(:command, Ryker.CoopFleet.Command)
    field(:worker_id, :string)
    field(:checkpoint_ref, :string)
    field(:session_ref, :string)
    field(:placement_generation, :integer)
    field(:repository_ref, :string)
    field(:descriptor, Ryker.CanonicalJSON.Type)
    field(:bundle_sha256, :string)
    field(:bundle_byte_size, :integer)
    field(:encryption_key_sha256, :string)
    field(:encryption_nonce, :binary)
    field(:encryption_tag, :binary)
    field(:ciphertext, :binary)

    timestamps(type: :utc_datetime_usec)
  end
end
