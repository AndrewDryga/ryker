defmodule Ryker.CoopFleet.Placement do
  @moduledoc false

  use Ecto.Schema

  # The states in which a placement still addresses its session: one of these
  # is the session's current placement until it is replaced or retired.
  @current_states [:assigning, :active, :draining, :revoking]

  @spec current_states() :: [atom()]
  def current_states, do: @current_states

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "coop_session_placements" do
    belongs_to(:session, Ryker.Work.Session)
    belongs_to(:episode, Ryker.Episodes.Episode)
    belongs_to(:worker, Ryker.CoopFleet.Worker, type: :string)
    field(:generation, :integer)
    field(:lease_ref, :string)
    field(:lease_expires_at, :utc_datetime_usec)

    field(:state, Ecto.Enum,
      values: [:assigning, :active, :draining, :revoking, :replaced, :retired],
      default: :assigning
    )

    field(:requirements, Ryker.CanonicalJSON.Type)
    field(:requirements_fingerprint, :string)
    field(:last_command_id, :binary_id)
    field(:last_acked_event_sequence, :integer, default: 0)
    field(:last_acked_session_event_sequence, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end
end
