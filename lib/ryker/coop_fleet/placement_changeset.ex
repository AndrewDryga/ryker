defmodule Ryker.CoopFleet.PlacementChangeset do
  @moduledoc "How a session's placement on a Coop worker changes (`Ryker.CoopFleet.Placement`)."
  import Ecto.Changeset
  alias Ryker.CoopFleet.Placement

  @fields [
    :episode_id,
    :generation,
    :id,
    :last_acked_event_sequence,
    :last_acked_session_event_sequence,
    :lease_expires_at,
    :lease_ref,
    :requirements,
    :requirements_fingerprint,
    :session_id,
    :state,
    :worker_id
  ]
  @required @fields --
              [:episode_id, :last_acked_event_sequence, :last_acked_session_event_sequence]

  @doc "A session placed on a worker at `at`, under a lease."
  def insert(attributes, at) do
    %Placement{inserted_at: at, updated_at: at}
    |> cast(attributes, @fields)
    |> validate_required(@required)
    |> unique_constraint([:session_id, :generation])
    |> unique_constraint(:session_id, name: :coop_session_placements_one_current)
    |> foreign_key_constraint(:session_id, name: :coop_session_placement_session_episode_fkey)
    |> foreign_key_constraint(:session_id, name: :coop_session_placements_session_id_fkey)
    |> foreign_key_constraint(:worker_id)
    |> check_constraint(:generation, name: :coop_session_placement_identity_valid)
  end

  @doc "The worker's poll keeps the placement until `expires_at`."
  def renew(%Placement{} = placement, expires_at),
    do: change(placement, lease_expires_at: expires_at)

  @doc "What the placement was granted no longer holds; its worker stops it."
  def revoke(%Placement{} = placement), do: change(placement, state: :revoking)

  @doc "Another placement takes the session, or nobody will renew this one."
  def replace(%Placement{} = placement), do: change(placement, state: :replaced)

  @doc "The worker session is gone, so nothing addresses the placement again."
  def retire(%Placement{} = placement), do: change(placement, state: :retired)

  @doc "The last command a poll delivered on the placement."
  def deliver_command(%Placement{} = placement, command_id),
    do: change(placement, last_command_id: command_id)

  @doc """
  The worker's events are recorded through `sequence`: its Coop session's
  events when `session_events?`, else its own.
  """
  def acknowledge_events(%Placement{} = placement, true, sequence) do
    placement
    |> change(last_acked_session_event_sequence: sequence)
    |> check_constraint(:last_acked_session_event_sequence,
      name: :coop_session_placement_session_event_cursor_valid
    )
  end

  def acknowledge_events(%Placement{} = placement, false, sequence) do
    placement
    |> change(last_acked_event_sequence: sequence)
    |> check_constraint(:last_acked_event_sequence, name: :coop_session_placement_identity_valid)
  end
end
