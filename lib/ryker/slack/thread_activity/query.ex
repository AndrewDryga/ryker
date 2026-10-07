defmodule Ryker.Slack.ThreadActivity.Query do
  @moduledoc """
  What the live Slack threads of a workspace are doing, as
  `Ryker.Slack.ThreadStatusProjection` reads it: recent messages and episodes,
  the turns that own working episodes, and what each running turn last said.
  """
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Work.{ActivityEvent, Turn}

  @doc """
  The `limit` latest live Slack messages of `workspace_ref` that are pending,
  blocked or changed since `cutoff`.
  """
  def recent_entries(workspace_ref, cutoff, limit) do
    from(entry in Entry,
      where:
        entry.source_kind == "slack" and entry.source_ref == ^workspace_ref and
          entry.destination_transport == "slack" and entry.execution_mode == :live and
          (entry.status in [:pending, :blocked] or entry.updated_at >= ^cutoff),
      order_by: [desc: entry.updated_at],
      limit: ^limit
    )
  end

  @doc """
  The `limit` latest live episodes of `workspace_ref`'s Slack conversations
  still under way or changed since `cutoff`.
  """
  def recent_episodes(workspace_ref, cutoff, limit) do
    from(episode in Episode,
      where:
        episode.destination_transport == "slack" and episode.execution_mode == :live and
          fragment(
            "split_part(?, ':', 1) = 'slack' AND split_part(?, ':', 2) = ?",
            episode.destination_conversation_ref,
            episode.destination_conversation_ref,
            ^workspace_ref
          ) and
          (episode.state in [:working, :waiting_for_input, :waiting_for_event] or
             episode.updated_at >= ^cutoff),
      order_by: [desc: episode.updated_at],
      limit: ^limit
    )
  end

  @doc """
  The turns of `episode_ids` with one of `turn_refs`, as maps of what a
  status needs; the caller keeps only the exact pairs.
  """
  def owning_turns(episode_ids, turn_refs) do
    from(turn in Turn,
      where: turn.episode_id in ^episode_ids and turn.turn_ref in ^turn_refs,
      select: %{
        coop_turn_id: turn.coop_turn_id,
        episode_id: turn.episode_id,
        session_id: turn.session_id,
        status: turn.status,
        turn_ref: turn.turn_ref
      }
    )
  end

  @doc """
  Each of `remote_turns`' latest step of `kinds`, a tool start before any
  narration, as `{{session_id, coop_turn_id}, {kind, payload}}`.
  """
  def latest_steps(remote_turns, kinds) do
    from(event in ActivityEvent,
      where: event.coop_turn_id in ^remote_turns and event.kind in ^kinds,
      distinct: [event.session_id, event.coop_turn_id],
      order_by: [desc: fragment("? = 'tool.started'", event.kind), desc: event.sequence],
      select: {{event.session_id, event.coop_turn_id}, {event.kind, event.payload}}
    )
  end

  @doc """
  When each of `remote_turns` last reported one of `kinds`, as
  `{{session_id, coop_turn_id}, occurred_at}`.
  """
  def last_heard(remote_turns, kinds) do
    from(event in ActivityEvent,
      where: event.coop_turn_id in ^remote_turns and event.kind in ^kinds,
      group_by: [event.session_id, event.coop_turn_id],
      select: {{event.session_id, event.coop_turn_id}, max(event.occurred_at)}
    )
  end
end
