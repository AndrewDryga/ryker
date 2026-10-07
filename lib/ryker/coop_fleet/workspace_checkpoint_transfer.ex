defmodule Ryker.CoopFleet.WorkspaceCheckpointTransfer do
  @moduledoc false
  use Ryker, :schema

  schema "coop_worker_workspace_checkpoints" do
    belongs_to(:command, Ryker.CoopFleet.Command)
    belongs_to(:body_command, Ryker.CoopFleet.Command)
    field(:worker_id, :string)
    field(:checkpoint_ref, :string)
    field(:session_ref, :string)
    field(:placement_generation, :integer)
    field(:repository_ref, :string)
    field(:descriptor, Ryker.CanonicalJSON.Type)
    field(:bundle_sha256, :string)
    field(:bundle_byte_size, :integer)
    field(:encryption_key_sha256, :string)

    timestamps()
  end
end
