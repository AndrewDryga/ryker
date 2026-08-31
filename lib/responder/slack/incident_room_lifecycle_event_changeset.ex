defmodule Responder.Slack.IncidentRoomLifecycleEventChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Slack.IncidentRoomLifecycleEvent

  @fields [
    :channel_ref,
    :event_fingerprint,
    :event_ref,
    :id,
    :kind,
    :occurred_at,
    :room_id,
    :workspace_ref
  ]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %IncidentRoomLifecycleEvent{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_length(:workspace_ref, min: 1, max: 256)
    |> validate_length(:channel_ref, min: 1, max: 256)
    |> validate_length(:event_ref, min: 1, max: 1_024)
    |> validate_length(:event_fingerprint, is: 64)
    |> unique_constraint([:workspace_ref, :event_ref])
    |> foreign_key_constraint(:room_id)
    |> check_constraint(:kind, name: :slack_incident_room_lifecycle_event_valid)
  end
end
