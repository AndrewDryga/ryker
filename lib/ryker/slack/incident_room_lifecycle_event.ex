defmodule Ryker.Slack.IncidentRoomLifecycleEvent do
  @moduledoc false
  use Ryker, :schema

  schema "slack_incident_room_lifecycle_events" do
    belongs_to(:room, Ryker.Slack.IncidentRoom)
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
    timestamps()
  end

  @type t :: %__MODULE__{}
end
