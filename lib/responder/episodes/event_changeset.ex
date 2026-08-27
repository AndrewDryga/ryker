defmodule Responder.Episodes.EventChangeset do
  @moduledoc false

  import Ecto.Changeset
  alias Responder.Episodes.Event

  @required_fields [
    :episode_id,
    :sequence,
    :kind,
    :dedupe_key,
    :fingerprint,
    :payload,
    :occurred_at
  ]

  @spec insert(Event.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def insert(%Event{} = event, episode_id) do
    event
    |> change(episode_id: episode_id)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:episode_id)
    |> unique_constraint([:episode_id, :sequence])
    |> unique_constraint([:episode_id, :dedupe_key])
    |> check_constraint(:sequence, name: :episode_kernel_event_sequence_positive)
    |> check_constraint(:dedupe_key, name: :episode_kernel_event_identity_valid)
    |> check_constraint(:kind, name: :episode_kernel_event_kind_valid)
  end
end
