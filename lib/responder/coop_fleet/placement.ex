defmodule Responder.CoopFleet.Placement do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "coop_session_placements" do
    belongs_to(:session, Responder.Work.Session)
    belongs_to(:episode, Responder.Episodes.Episode)
    belongs_to(:worker, Responder.CoopFleet.Worker, type: :string)
    field(:generation, :integer)
    field(:lease_ref, :string)
    field(:lease_expires_at, :utc_datetime_usec)

    field(:state, Ecto.Enum,
      values: [:assigning, :active, :draining, :revoking, :replaced, :retired],
      default: :assigning
    )

    field(:requirements, Responder.CanonicalJSON.Type)
    field(:requirements_fingerprint, :string)
    field(:last_command_id, :binary_id)
    field(:last_acked_event_sequence, :integer, default: 0)
    field(:last_acked_session_event_sequence, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end
end
