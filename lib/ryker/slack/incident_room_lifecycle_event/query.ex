defmodule Ryker.Slack.IncidentRoomLifecycleEvent.Query do
  @moduledoc "What happened to each incident room's channel, for every read of `slack_incident_room_lifecycle_events`."
  use Ryker, :query
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

  def by_room_id(queryable \\ all(), room_id),
    do: where(queryable, [slack_incident_room_lifecycle_events: e], e.room_id == ^room_id)

  def ordered_by_occurred_at(queryable) do
    order_by(queryable, [slack_incident_room_lifecycle_events: e],
      asc: e.occurred_at,
      asc: e.id
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
