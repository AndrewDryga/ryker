defmodule Ryker.Slack.IncidentRoomLifecycleEventQuery do
  @moduledoc "What happened to each incident room's channel, for every read of `slack_incident_room_lifecycle_events`."
  import Ecto.Query
  alias Ryker.Slack.IncidentRoomLifecycleEvent

  def all,
    do: from(events in IncidentRoomLifecycleEvent, as: :slack_incident_room_lifecycle_events)

  @doc "Slack event `event_ref` of workspace `workspace_ref`."
  def by_event(workspace_ref, event_ref) do
    where(
      all(),
      [slack_incident_room_lifecycle_events: e],
      e.workspace_ref == ^workspace_ref and e.event_ref == ^event_ref
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
