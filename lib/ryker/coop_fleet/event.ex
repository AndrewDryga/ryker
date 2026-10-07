defmodule Ryker.CoopFleet.Event do
  @moduledoc false
  use Ryker, :schema
  # Events are numbered as they arrive: a bigserial, not a UUID.
  @primary_key {:id, :id, autogenerate: true}

  schema "coop_worker_events" do
    belongs_to(:placement, Ryker.CoopFleet.Placement)
    field(:worker_id, :string)
    field(:session_id, :binary_id)
    field(:placement_generation, :integer)
    field(:sequence, :integer)
    field(:kind, :string)
    field(:payload, Ryker.CanonicalJSON.Type)
    field(:payload_fingerprint, :string)

    timestamps(updated_at: false)
  end
end
