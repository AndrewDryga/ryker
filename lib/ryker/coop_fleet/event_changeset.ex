defmodule Ryker.CoopFleet.EventChangeset do
  @moduledoc "How an event a worker reported is recorded (`Ryker.CoopFleet.Event`)."
  import Ecto.Changeset
  alias Ryker.CoopFleet.Event

  @fields [
    :kind,
    :payload,
    :payload_fingerprint,
    :placement_generation,
    :placement_id,
    :sequence,
    :session_id,
    :worker_id
  ]

  @doc "One event of a placement's batch, at its sequence."
  def insert(attributes) do
    %Event{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:placement_id, :sequence])
    |> foreign_key_constraint(:placement_id, name: :coop_worker_event_placement_identity_fkey)
    |> check_constraint(:kind, name: :coop_worker_event_identity_valid)
  end
end
