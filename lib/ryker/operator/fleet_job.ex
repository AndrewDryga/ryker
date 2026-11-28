defmodule Ryker.Operator.FleetJob do
  @moduledoc "A local operator's idempotent request and the exact episode created for it."
  use Ryker, :schema

  schema "operator_fleet_jobs" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    field(:resources, :map)
    field(:workspace_input, :map)
    field(:workspace_input_id, Ecto.UUID)
    field(:request_digest, :string)
    field(:environment_ref, :string)
    field(:repository_ref, :string)
    timestamps(updated_at: false)
  end
end
