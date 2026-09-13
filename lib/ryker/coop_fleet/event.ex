defmodule Ryker.CoopFleet.Event do
  @moduledoc false

  use Ecto.Schema

  @foreign_key_type :binary_id

  schema "coop_worker_events" do
    belongs_to(:placement, Ryker.CoopFleet.Placement)
    field(:worker_id, :string)
    field(:session_id, :binary_id)
    field(:placement_generation, :integer)
    field(:sequence, :integer)
    field(:kind, :string)
    field(:payload, Ryker.CanonicalJSON.Type)
    field(:payload_fingerprint, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
