defmodule Ryker.CoopFleet.Command do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "coop_worker_commands" do
    belongs_to(:placement, Ryker.CoopFleet.Placement)
    field(:worker_id, :string)
    field(:session_id, :binary_id)
    field(:placement_generation, :integer)
    field(:kind, :string)
    field(:command_version, :integer, default: 1)
    field(:payload, Ryker.CanonicalJSON.Type)
    field(:payload_fingerprint, :string)
    field(:idempotency_key, :string)

    field(:status, Ecto.Enum,
      values: [:queued, :delivered, :acknowledged, :succeeded, :failed, :uncertain],
      default: :queued
    )

    field(:operation_key, :string)
    field(:result, Ryker.CanonicalJSON.Type)
    field(:error, Ryker.CanonicalJSON.Type)
    field(:result_fingerprint, :string)
    field(:delivered_at, :utc_datetime_usec)
    field(:acknowledged_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end
end
