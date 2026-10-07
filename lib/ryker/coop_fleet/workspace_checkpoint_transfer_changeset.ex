defmodule Ryker.CoopFleet.WorkspaceCheckpointTransferChangeset do
  @moduledoc """
  How a workspace checkpoint a worker sent is recorded
  (`Ryker.CoopFleet.WorkspaceCheckpointTransfer`).
  """
  import Ecto.Changeset
  alias Ryker.CoopFleet.WorkspaceCheckpointTransfer

  @fields [
    :id,
    :command_id,
    :body_command_id,
    :worker_id,
    :session_ref,
    :placement_generation,
    :repository_ref,
    :checkpoint_ref,
    :descriptor,
    :bundle_sha256,
    :bundle_byte_size,
    :encryption_key_sha256
  ]

  @doc "A checkpoint whose bundle was checked and stored before this records it."
  def insert(attributes) do
    %WorkspaceCheckpointTransfer{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
  end
end
