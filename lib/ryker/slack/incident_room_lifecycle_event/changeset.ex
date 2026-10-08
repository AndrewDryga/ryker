defmodule Ryker.Slack.IncidentRoomLifecycleEvent.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Slack.IncidentRoomLifecycleEvent

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
    |> validate_length(:workspace_ref, min: 1, max: 256, count: :codepoints)
    |> validate_length(:channel_ref, min: 1, max: 256, count: :codepoints)
    |> validate_length(:event_ref, min: 1, max: 1_024, count: :codepoints)
    |> validate_length(:event_fingerprint, is: 64, count: :codepoints)
    # PostgreSQL cut the index's name to its 63-byte limit, and a violation
    # reports that name, never the one Ecto would infer.
    |> unique_constraint(:event_ref,
      name: :slack_incident_room_lifecycle_events_workspace_ref_event_ref_in
    )
    |> foreign_key_constraint(:room_id)
    |> check_constraint(:kind, name: :slack_incident_room_lifecycle_event_valid)
  end
end
