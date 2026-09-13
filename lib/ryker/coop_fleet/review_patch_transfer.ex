defmodule Ryker.CoopFleet.ReviewPatchTransfer do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "coop_worker_review_patch_transfers" do
    belongs_to(:command, Ryker.CoopFleet.Command)
    field(:worker_id, :string)
    field(:artifact_id, :string)
    field(:sha256, :string)
    field(:byte_size, :integer)
    field(:data, :binary)

    timestamps(type: :utc_datetime_usec)
  end
end
