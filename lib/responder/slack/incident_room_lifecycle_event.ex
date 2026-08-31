defmodule Responder.Slack.IncidentRoomLifecycleEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "slack_incident_room_lifecycle_events" do
    belongs_to(:room, Responder.Slack.IncidentRoom)
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:event_ref, :string)
    field(:event_fingerprint, :string)

    field(:kind, Ecto.Enum,
      values: [
        :joined,
        :left,
        :archived,
        :unarchived,
        :deleted,
        :observed_active,
        :observed_archived,
        :observed_unavailable
      ]
    )

    field(:occurred_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
