defmodule Ryker.Slack.AppHome.Query do
  @moduledoc """
  What a person's App Home reads of a workspace (`Ryker.Slack.AppHomeProjection`):
  counts, what needs attention, work in progress, incidents, behaviors, facts
  and schedules. `destination_refs` are the Slack conversations the person
  may see, `channel_refs` their channel ids.
  """
  import Ecto.Query
  alias Ryker.Behaviors.Behavior
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Publication.Publication
  alias Ryker.Schedules.Schedule
  alias Ryker.Slack.IncidentRoom
  alias Ryker.Work.{Session, Turn}

  @active_episode_states [:working, :waiting_for_input, :waiting_for_event]

  @doc "Active, unexpired behaviors of `workspace_ref` that `actor_ref` may see."
  def active_behaviors(workspace_ref, actor_ref, now) do
    from(behavior in Behavior,
      where:
        behavior.workspace_ref == ^workspace_ref and behavior.status == :active and
          (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
      where: ^behavior_visibility(actor_ref)
    )
  end

  @doc "The `limit` latest active or paused, unexpired behaviors `actor_ref` may see."
  def listed_behaviors(workspace_ref, actor_ref, now, limit) do
    from(behavior in Behavior,
      where:
        behavior.workspace_ref == ^workspace_ref and behavior.status in [:active, :disabled] and
          (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
      where: ^behavior_visibility(actor_ref),
      order_by: [desc: behavior.updated_at, desc: behavior.id],
      limit: ^limit,
      select: behavior
    )
  end

  # Guidance shows when it is the person's own private guidance or visible to
  # the whole workspace; any other behavior when it is theirs or the workspace's.
  defp behavior_visibility(actor_ref) do
    dynamic(
      [behavior],
      fragment(
        """
        CASE WHEN ? = 'guidance' THEN
          ((? = 'operator' AND ? = ? AND (?::jsonb)->>'visibility' = 'private') OR
           (? IN ('repository', 'workspace') AND (?::jsonb)->>'visibility' = 'workspace'))
        ELSE
          ((? = 'operator' AND ? = ?) OR ? IN ('repository', 'workspace'))
        END
        """,
        behavior.kind,
        behavior.scope_kind,
        behavior.scope_ref,
        ^actor_ref,
        behavior.payload,
        behavior.scope_kind,
        behavior.payload,
        behavior.scope_kind,
        behavior.scope_ref,
        ^actor_ref,
        behavior.scope_kind
      )
    )
  end

  @doc "Episodes of the person's Slack conversations still under way."
  def active_commitments(destination_refs) do
    from(episode in Episode,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref in ^destination_refs and
          episode.state in ^@active_episode_states
    )
  end

  @doc "Active, unexpired facts of `workspace_ref` the whole workspace may see."
  def workspace_facts(workspace_ref, now) do
    from(memory in MemoryEntry,
      where:
        memory.workspace_ref == ^workspace_ref and memory.status == :active and
          memory.expires_at > ^now and memory.visibility == :workspace and
          memory.scope_kind in [:repository, :workspace]
    )
  end

  @doc "The `limit` latest of `workspace_facts/2`."
  def listed_facts(workspace_ref, now, limit) do
    from(memory in workspace_facts(workspace_ref, now),
      order_by: [desc: memory.updated_at, desc: memory.id],
      limit: ^limit,
      select: memory
    )
  end

  @doc "Active, unexpired schedules of the person's Slack conversations."
  def active_schedules(destination_refs, now) do
    from(schedule in Schedule,
      where:
        schedule.destination_transport == "slack" and
          schedule.destination_conversation_ref in ^destination_refs and
          schedule.status == :active and
          (is_nil(schedule.expires_at) or schedule.expires_at > ^now)
    )
  end

  @doc "The `limit` next schedules of the person's conversations, active, paused or done, unexpired."
  def listed_schedules(destination_refs, now, limit) do
    from(schedule in Schedule,
      where:
        schedule.destination_transport == "slack" and
          schedule.destination_conversation_ref in ^destination_refs and
          schedule.status in [:active, :paused, :completed] and
          (is_nil(schedule.expires_at) or schedule.expires_at > ^now),
      order_by: [asc: schedule.next_occurrence_at, asc: schedule.id],
      limit: ^limit
    )
  end

  @doc "Working episodes of the person's conversations whose owning turn is blocked."
  def blocked_turns(destination_refs) do
    from(turn in Turn,
      join: episode in Episode,
      on:
        episode.id == turn.episode_id and episode.owner_kind == :turn and
          episode.owner_ref == turn.turn_ref,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref in ^destination_refs and
          episode.state == :working and turn.status == :blocked
    )
  end

  @doc "The `limit` latest of `blocked_turns/1`, as `{episode, blocked_at}`."
  def listed_blocked_turns(destination_refs, limit) do
    from([turn, episode] in blocked_turns(destination_refs),
      order_by: [desc: turn.updated_at, desc: turn.id],
      limit: ^limit,
      select: {episode, turn.updated_at}
    )
  end

  @doc "Incident rooms of the person's channels, closed (`:closed`) or not (`:open`)."
  def incidents(workspace_ref, channel_refs, :closed) do
    from(room in IncidentRoom,
      where:
        room.workspace_ref == ^workspace_ref and room.channel_ref in ^channel_refs and
          room.status == :closed
    )
  end

  def incidents(workspace_ref, channel_refs, :open) do
    from(room in IncidentRoom,
      where:
        room.workspace_ref == ^workspace_ref and room.channel_ref in ^channel_refs and
          room.status != :closed
    )
  end

  @doc "The `limit` latest open rooms of the person's channels."
  def listed_open_incidents(workspace_ref, channel_refs, limit) do
    from(room in incidents(workspace_ref, channel_refs, :open),
      order_by: [desc: room.updated_at, desc: room.id],
      limit: ^limit,
      select: room
    )
  end

  @doc "The `limit` latest blocked rooms of the person's channels."
  def blocked_incidents(workspace_ref, channel_refs, limit) do
    from(room in IncidentRoom,
      where:
        room.workspace_ref == ^workspace_ref and room.channel_ref in ^channel_refs and
          room.status == :blocked,
      order_by: [desc: room.updated_at, desc: room.id],
      limit: ^limit,
      select: room
    )
  end

  @doc "Publications of the person's conversations that went out."
  def published_work(destination_refs) do
    from(publication in Publication,
      where:
        publication.destination_transport == "slack" and
          publication.destination_conversation_ref in ^destination_refs and
          publication.status == :published
    )
  end

  @doc """
  The `limit` latest publications of the person's conversations a person has
  to act on: stopped on a branch conflict (one of `conflicts`), failing,
  waiting for approval, or published from a head that moved.
  """
  def publication_attention(destination_refs, conflicts, limit) do
    conflict =
      dynamic(
        [publication],
        publication.status == :publish_pending and publication.last_error_code in ^conflicts
      )

    failed =
      dynamic(
        [publication],
        publication.status in [:review_pending, :review_ready, :publish_pending, :published_ready] and
          not is_nil(publication.last_error_code)
      )

    unapproved =
      dynamic(
        [publication],
        publication.status in [:reviewed, :blocked] and is_nil(publication.approval_ref)
      )

    stale =
      dynamic(
        [publication],
        publication.status == :published and not is_nil(publication.expected_remote_head_sha)
      )

    from(publication in Publication,
      where:
        publication.destination_transport == "slack" and
          publication.destination_conversation_ref in ^destination_refs,
      where: ^dynamic([publication], ^conflict or ^failed or ^unapproved or ^stale),
      order_by: [desc: publication.updated_at, desc: publication.id],
      limit: ^limit
    )
  end

  @doc "Retained working copies of the person's conversations."
  def retained_workspaces(destination_refs) do
    from(session in Session,
      join: episode in Episode,
      on: episode.id == session.episode_id,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref in ^destination_refs and
          session.cleanup_status == :retained
    )
  end

  @doc """
  The `limit` latest retained working copies of the person's conversations
  that hold only unmerged, clean work with a discard plan, as `{session,
  episode}`.
  """
  def unmerged_workspaces(destination_refs, limit) do
    from([session, episode] in retained_workspaces(destination_refs),
      where:
        session.retained_reason == "unpublished_unmerged" and not is_nil(session.external_ref) and
          not is_nil(session.discard_plan_fingerprint) and
          fragment("(?::jsonb)->'workspace'->>'dirty' = 'false'", session.discard_plan) and
          fragment("(?::jsonb)->'workspace'->>'unmerged' = 'true'", session.discard_plan),
      order_by: [desc: session.updated_at, desc: session.id],
      limit: ^limit,
      select: {session, episode}
    )
  end

  @doc "The `limit` latest episodes of the person's conversations waiting for a person."
  def operator_waits(destination_refs, limit) do
    from(episode in Episode,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref in ^destination_refs and
          episode.state == :waiting_for_input,
      order_by: [desc: episode.updated_at, desc: episode.id],
      limit: ^limit,
      select: episode
    )
  end

  @doc """
  The `limit` latest episodes of the person's conversations still under way,
  with the status and Coop turn of the turn that owns each, as `{episode,
  turn_status, coop_turn_id}`.
  """
  def work(destination_refs, limit) do
    from(episode in active_commitments(destination_refs),
      left_join: turn in Turn,
      on:
        turn.episode_id == episode.id and episode.owner_kind == :turn and
          turn.turn_ref == episode.owner_ref,
      order_by: [desc: episode.updated_at, desc: episode.id],
      limit: ^limit,
      select: {episode, turn.status, turn.coop_turn_id}
    )
  end

  @doc "Each of `episode_ids`' latest session's task, as `{episode_id, workspace_task}`."
  def latest_tasks(episode_ids) do
    from(session in Session,
      where: session.episode_id in ^episode_ids,
      distinct: session.episode_id,
      order_by: [asc: session.episode_id, desc: session.generation, desc: session.id],
      select: {session.episode_id, session.workspace_task}
    )
  end

  @doc "Each of `episode_ids`' first admitted input, as `{episode_id, payload}`."
  def first_inputs(episode_ids) do
    from(event in Event,
      where: event.episode_id in ^episode_ids and event.kind == :input_admitted,
      distinct: event.episode_id,
      order_by: [asc: event.episode_id, asc: event.sequence],
      select: {event.episode_id, event.payload}
    )
  end
end
