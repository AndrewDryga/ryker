defmodule Ryker.ControlPlane.EpisodeTrace.Query do
  @moduledoc """
  What a request's timeline reads across tables (`Ryker.ControlPlane.EpisodeTrace`
  and its chapters): its messages as they read now, each revision beside its
  message's current one, the offer a task started from, the incident rooms a
  request belongs to, and the requests linked to it.
  """
  use Ryker, :query
  alias Ryker.ControlPlane.CurrentInput
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Records.Record
  alias Ryker.Slack.IncidentRoom

  @doc "The messages of `episode_id`, each once, as they read now (`CurrentInput.Query.by_episode_id/1`)."
  def messages(episode_id),
    do: from(entry in subquery(CurrentInput.Query.by_episode_id(episode_id)), as: :messages)

  def ordered_by_occurred_at(queryable),
    do: order_by(queryable, [messages: e], asc: e.occurred_at, asc: e.id)

  def ordered_by_occurred_at_desc(queryable),
    do: order_by(queryable, [messages: e], desc: e.occurred_at, desc: e.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc """
  The `limit` newest revisions `episode_id` admitted, each beside the current
  revision of its message, which may have arrived anywhere, as `{entry,
  {current_id, current_event_kind}}`.
  """
  def revisions(episode_id, limit) do
    from(entry in Entry,
      as: :revision,
      inner_lateral_join: current in subquery(CurrentInput.Query.current()),
      on: true,
      where: entry.episode_id == ^episode_id,
      order_by: [desc: entry.occurred_at, desc: entry.id],
      limit: ^limit,
      select: {entry, {current.id, current.event_kind}}
    )
  end

  @doc """
  The confirmed offer `episode`'s task started from, made in the request it
  is linked to (or itself), as `%{inserted_at, confirmed_at, episode_id}`.
  """
  def task_offer(%Episode{} = episode) do
    from(record in Record,
      join: source in Episode,
      on: source.id == record.episode_id,
      where: record.kind == "task_offer" and record.status == :confirmed,
      where: record.confirmed_episode_id == ^episode.id,
      where: record.episode_id == ^(episode.linked_episode_id || episode.id),
      select: %{
        inserted_at: record.inserted_at,
        confirmed_at: record.confirmed_at,
        episode_id: source.id
      },
      order_by: [desc: record.confirmed_at, desc: record.id],
      limit: 1
    )
  end

  @doc """
  The incident rooms `episode_id` investigates, and, given a Slack `{workspace,
  channel}`, the rooms of that channel.
  """
  def incident_rooms(episode_id, nil),
    do: from(room in IncidentRoom, where: room.episode_id == ^episode_id)

  def incident_rooms(episode_id, {workspace, channel}) do
    from(room in IncidentRoom,
      where:
        room.episode_id == ^episode_id or
          (room.workspace_ref == ^workspace and room.channel_ref == ^channel)
    )
  end

  @doc """
  The requests of `episode`'s conversation linked to it, or that it is
  linked to, oldest first, `limit` at most.
  """
  def related(%Episode{} = episode, limit) do
    from(other in Episode,
      where: other.destination_transport == ^episode.destination_transport,
      where: other.destination_conversation_ref == ^episode.destination_conversation_ref,
      where:
        other.linked_episode_id == ^episode.id or
          other.id == ^(episode.linked_episode_id || episode.id),
      where: other.id != ^episode.id,
      order_by: [asc: other.inserted_at, asc: other.id],
      limit: ^limit
    )
  end
end
