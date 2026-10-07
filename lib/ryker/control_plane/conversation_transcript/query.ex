defmodule Ryker.ControlPlane.ConversationTranscript.Query do
  @moduledoc """
  What each row of a direct conversation's transcript shows
  (`Ryker.ControlPlane.ConversationTranscript`): the state of the work a
  message started, the current revision of each message, and the reactions
  on messages.
  """
  import Ecto.Query
  alias Ryker.Delivery.{PlatformAction, RoutingResponse}
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Work.Turn

  @doc """
  Each of `episode_ids` as its messages show it, as `%{id, active_input_refs,
  state}`: the episode's state, or `"blocked"` while its owning turn is.
  """
  def executions(episode_ids) do
    from(episode in Episode,
      left_join: turn in Turn,
      on:
        turn.episode_id == episode.id and turn.turn_ref == episode.owner_ref and
          episode.owner_kind == :turn,
      where: episode.id in ^episode_ids,
      select: %{
        id: episode.id,
        active_input_refs: episode.active_input_refs,
        state:
          fragment(
            "CASE WHEN ? = 'blocked' THEN 'blocked' ELSE ?::text END",
            turn.status,
            episode.state
          )
      }
    )
  end

  @doc """
  The current revision of each local message of `native_input_ids`, as
  `{native_input_id, {revision, event_kind}}`.
  """
  def current_revisions(native_input_ids) do
    from(entry in Entry,
      where:
        entry.source_kind == "control_plane" and entry.source_ref == "local" and
          entry.native_input_id in ^native_input_ids,
      distinct: entry.native_input_id,
      order_by: [
        asc: entry.native_input_id,
        desc: entry.revision,
        desc: entry.inserted_at,
        desc: entry.id
      ],
      select: {entry.native_input_id, {entry.revision, entry.event_kind}}
    )
  end

  @doc """
  The reactions routing put on the messages `item_refs` names, oldest first,
  `limit` at most, as `%{delivery_ref, emoji_name, source_item_ref, status}`.
  """
  def routing_reactions(item_refs, limit) do
    from(reaction in RoutingResponse,
      where:
        reaction.kind == :reaction and reaction.transport == "control_plane" and
          reaction.source_item_ref in ^item_refs,
      order_by: [asc: reaction.inserted_at, asc: reaction.id],
      limit: ^limit,
      select: %{
        delivery_ref: reaction.delivery_ref,
        emoji_name: fragment("(?::jsonb ->> 'emoji_name')", reaction.document),
        source_item_ref: reaction.source_item_ref,
        status: reaction.status
      }
    )
  end

  @doc """
  The reactions Work put on the messages `item_refs` names, oldest first,
  `limit` at most, as `%{action_ref, document, source_item_ref, status}`.
  """
  def work_reactions(item_refs, limit) do
    from(action in PlatformAction,
      where:
        action.transport == "control_plane" and action.kind == :reaction and
          action.source_item_ref in ^item_refs,
      order_by: [asc: action.inserted_at, asc: action.id],
      limit: ^limit,
      select: %{
        action_ref: action.action_ref,
        document: action.document,
        source_item_ref: action.source_item_ref,
        status: action.status
      }
    )
  end
end
