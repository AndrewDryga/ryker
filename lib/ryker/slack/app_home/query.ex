defmodule Ryker.Slack.AppHome.Query do
  @moduledoc """
  What a person's App Home reads of a workspace (`Ryker.Slack.AppHomeProjection`):
  counts, what needs attention, work in progress, incidents, behaviors, facts
  and schedules. `destination_refs` are the Slack conversations the person
  may see, `channel_refs` their channel ids.
  """
  use Ryker, :query
  alias Ryker.Behaviors
  alias Ryker.Episodes
  alias Ryker.Memories
  alias Ryker.Publication
  alias Ryker.Schedules
  alias Ryker.Slack.IncidentRoom
  alias Ryker.Work

  @active_episode_states [:working, :waiting_for_input, :waiting_for_event]

  @doc "Active, unexpired behaviors of `workspace_ref` that `actor_ref` may see."
  def active_behaviors(workspace_ref, actor_ref, now) do
    from([operator_behaviors: behavior] in Behaviors.Behavior.Query.all(),
      where:
        behavior.workspace_ref == ^workspace_ref and behavior.status == :active and
          (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
      where: ^behavior_visibility(actor_ref)
    )
  end

  @doc "The `limit` latest active or paused, unexpired behaviors `actor_ref` may see."
  def listed_behaviors(workspace_ref, actor_ref, now, limit) do
    from([operator_behaviors: behavior] in Behaviors.Behavior.Query.all(),
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
      [operator_behaviors: b],
      fragment(
        """
        CASE WHEN ? = 'guidance' THEN
          ((? = 'operator' AND ? = ? AND (?::jsonb)->>'visibility' = 'private') OR
           (? IN ('repository', 'workspace') AND (?::jsonb)->>'visibility' = 'workspace'))
        ELSE
          ((? = 'operator' AND ? = ?) OR ? IN ('repository', 'workspace'))
        END
        """,
        b.kind,
        b.scope_kind,
        b.scope_ref,
        ^actor_ref,
        b.payload,
        b.scope_kind,
        b.payload,
        b.scope_kind,
        b.scope_ref,
        ^actor_ref,
        b.scope_kind
      )
    )
  end

  @doc "Episodes of the person's Slack conversations still under way."
  def active_commitments(destination_refs) do
    from(episode in Episodes.Episode,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref in ^destination_refs and
          episode.state in ^@active_episode_states
    )
  end

  @doc "Active, unexpired facts of `workspace_ref` the whole workspace may see."
  def workspace_facts(workspace_ref, now) do
    from(memory in Memories.MemoryEntry,
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
    from(schedule in Schedules.Schedule,
      where:
        schedule.destination_transport == "slack" and
          schedule.destination_conversation_ref in ^destination_refs and
          schedule.status == :active and
          (is_nil(schedule.expires_at) or schedule.expires_at > ^now)
    )
  end

  @doc "The `limit` next schedules of the person's conversations, active, paused or done, unexpired."
  def listed_schedules(destination_refs, now, limit) do
    from(schedule in Schedules.Schedule,
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
    from([episode_work_turns: turn] in Work.Turn.Query.all(),
      join: episode in Episodes.Episode,
      as: :episode_kernel_episodes,
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
    from(
      [episode_work_turns: turn, episode_kernel_episodes: episode] in blocked_turns(
        destination_refs
      ),
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
    from(publication in Publication.Publication,
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
        [episode_publications: p],
        p.status == :publish_pending and p.last_error_code in ^conflicts
      )

    failed =
      dynamic(
        [episode_publications: p],
        p.status in [:review_pending, :review_ready, :publish_pending, :published_ready] and
          not is_nil(p.last_error_code)
      )

    unapproved =
      dynamic(
        [episode_publications: p],
        p.status in [:reviewed, :blocked] and is_nil(p.approval_ref)
      )

    stale =
      dynamic(
        [episode_publications: p],
        p.status == :published and not is_nil(p.expected_remote_head_sha)
      )

    from([episode_publications: p] in Publication.Publication.Query.all(),
      where:
        p.destination_transport == "slack" and
          p.destination_conversation_ref in ^destination_refs,
      where: ^dynamic(^conflict or ^failed or ^unapproved or ^stale),
      order_by: [desc: p.updated_at, desc: p.id],
      limit: ^limit
    )
  end

  @doc "Retained working copies of the person's conversations."
  def retained_workspaces(destination_refs) do
    from([episode_work_sessions: session] in Work.Session.Query.all(),
      join: episode in Episodes.Episode,
      as: :episode_kernel_episodes,
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
    from(
      [episode_work_sessions: session, episode_kernel_episodes: episode] in retained_workspaces(
        destination_refs
      ),
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
    from(episode in Episodes.Episode,
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
      left_join: turn in Work.Turn,
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
    from(session in Work.Session,
      where: session.episode_id in ^episode_ids,
      distinct: session.episode_id,
      order_by: [asc: session.episode_id, desc: session.generation, desc: session.id],
      select: {session.episode_id, session.workspace_task}
    )
  end

  @doc "Each of `episode_ids`' first admitted input, as `{episode_id, payload}`."
  def first_inputs(episode_ids) do
    from(event in Episodes.Event,
      where: event.episode_id in ^episode_ids and event.kind == :input_admitted,
      distinct: event.episode_id,
      order_by: [asc: event.episode_id, asc: event.sequence],
      select: {event.episode_id, event.payload}
    )
  end
end
