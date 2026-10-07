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

  def of_room(queryable \\ all(), room_id),
    do: where(queryable, [slack_incident_room_lifecycle_events: e], e.room_id == ^room_id)

  def in_order(queryable) do
    order_by(queryable, [slack_incident_room_lifecycle_events: e],
      asc: e.occurred_at,
      asc: e.id
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc "What a room's report lists of each change: `%{kind, occurred_at, channel_ref}`."
  def select_timeline(queryable) do
    select(queryable, [slack_incident_room_lifecycle_events: e], %{
      kind: e.kind,
      occurred_at: e.occurred_at,
      channel_ref: e.channel_ref
    })
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
