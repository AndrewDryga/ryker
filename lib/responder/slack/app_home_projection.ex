defmodule Responder.Slack.AppHomeProjection do
  @moduledoc """
  Bounded read model for Slack App Home.

  The projection never grants authority and never reads raw input or model
  payloads. It exposes only lifecycle identity, short operator-authored titles,
  counts, and the next host-owned action for one exact Slack workspace.
  """

  import Ecto.Query

  alias Responder.Episodes.Episode
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.Slack.IncidentRoom
  alias Responder.State.{Behavior, Memories, MemoryEntry, Schedule}
  alias Responder.Work.Turn

  @active_episode_states [:working, :waiting_for_input, :waiting_for_event]
  @maximum_attention 8
  @maximum_work 8
  @maximum_incidents 5
  @maximum_behaviors 5
  @maximum_memories 5
  @maximum_memory_reviews 2
  @maximum_schedules 5

  @spec snapshot(String.t(), String.t()) :: map()
  def snapshot(workspace_ref, actor_ref) do
    if workspace_ref?(workspace_ref) and actor_ref?(actor_ref) do
      now = database_now!()
      prefix = "slack:#{workspace_ref}:%"

      actor_scope = "slack:user:#{actor_ref}"
      workspace_scope = "slack:#{workspace_ref}"

      memory_reviews =
        Memories.home_reviews(workspace_scope, actor_scope, limit: @maximum_memory_reviews)

      %{
        behaviors: behaviors(workspace_ref, "slack:user:#{actor_ref}", now),
        counts: counts(workspace_ref, prefix, now),
        incidents: incidents(workspace_ref),
        memories: memories("slack:#{workspace_ref}", now),
        memory_review_count: memory_reviews.total,
        memory_reviews: memory_reviews.items,
        needs_attention: needs_attention(workspace_ref, prefix),
        schedules: schedules(prefix, now),
        work: work(prefix)
      }
    else
      empty()
    end
  end

  @spec empty() :: map()
  def empty do
    %{
      counts: %{
        active_behaviors: 0,
        active_commitments: 0,
        active_memory: 0,
        active_schedules: 0,
        blocked_work: 0,
        incident_history: 0,
        open_incidents: 0,
        published_work: 0
      },
      behaviors: [],
      incidents: [],
      memories: [],
      memory_review_count: 0,
      memory_reviews: [],
      needs_attention: [],
      schedules: [],
      work: []
    }
  end

  defp counts(workspace_ref, prefix, now) do
    %{
      active_behaviors: active_behavior_count(workspace_ref, now),
      active_commitments: active_commitment_count(prefix),
      active_memory: active_memory_count("slack:#{workspace_ref}", now),
      active_schedules: active_schedule_count(prefix, now),
      blocked_work: blocked_work_count(prefix),
      incident_history: incident_count(workspace_ref, :closed),
      open_incidents: incident_count(workspace_ref, :open),
      published_work: published_work_count(prefix)
    }
  end

  defp needs_attention(workspace_ref, prefix) do
    (operator_waits(prefix) ++
       blocked_work(prefix) ++ publication_attention(prefix) ++ incident_attention(workspace_ref))
    |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.ref}, :desc)
    |> Enum.take(@maximum_attention)
    |> Enum.map(&Map.delete(&1, :updated_at))
  end

  defp active_behavior_count(workspace_ref, now) do
    count(
      from(behavior in Behavior,
        where:
          behavior.workspace_ref == ^workspace_ref and behavior.status == :active and
            behavior.expires_at > ^now
      )
    )
  end

  defp active_commitment_count(prefix) do
    count(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and
            like(episode.destination_conversation_ref, ^prefix) and
            episode.state in ^@active_episode_states
      )
    )
  end

  defp active_memory_count(workspace_ref, now) do
    count(
      from(memory in MemoryEntry,
        where:
          memory.workspace_ref == ^workspace_ref and memory.status == :active and
            memory.expires_at > ^now
      )
    )
  end

  defp active_schedule_count(prefix, now) do
    count(
      from(schedule in Schedule,
        where:
          schedule.destination_transport == "slack" and
            like(schedule.destination_conversation_ref, ^prefix) and
            schedule.status == :active and
            (is_nil(schedule.expires_at) or schedule.expires_at > ^now)
      )
    )
  end

  defp blocked_work_count(prefix) do
    count(
      from(turn in Turn,
        join: episode in Episode,
        on:
          episode.id == turn.episode_id and episode.owner_kind == :turn and
            episode.owner_ref == turn.turn_ref,
        where:
          episode.destination_transport == "slack" and
            like(episode.destination_conversation_ref, ^prefix) and
            episode.state == :working and turn.status == :blocked
      )
    )
  end

  defp incident_count(workspace_ref, :closed) do
    count(
      from(room in IncidentRoom,
        where: room.workspace_ref == ^workspace_ref and room.status == :closed
      )
    )
  end

  defp incident_count(workspace_ref, :open) do
    count(
      from(room in IncidentRoom,
        where: room.workspace_ref == ^workspace_ref and room.status != :closed
      )
    )
  end

  defp published_work_count(prefix) do
    count(
      from(publication in Publication,
        where:
          publication.destination_transport == "slack" and
            like(publication.destination_conversation_ref, ^prefix) and
            publication.status == :published
      )
    )
  end

  defp operator_waits(prefix) do
    Repo.all(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and
            like(episode.destination_conversation_ref, ^prefix) and
            episode.state == :waiting_for_input,
        order_by: [desc: episode.updated_at, desc: episode.id],
        limit: ^@maximum_attention,
        select: %{
          kind: :operator_input,
          ref: episode.key,
          title: episode.key,
          updated_at: episode.updated_at
        }
      )
    )
  end

  defp blocked_work(prefix) do
    Repo.all(
      from(turn in Turn,
        join: episode in Episode,
        on:
          episode.id == turn.episode_id and episode.owner_kind == :turn and
            episode.owner_ref == turn.turn_ref,
        where:
          episode.destination_transport == "slack" and
            like(episode.destination_conversation_ref, ^prefix) and
            episode.state == :working and turn.status == :blocked,
        order_by: [desc: turn.updated_at, desc: turn.id],
        limit: ^@maximum_attention,
        select: %{
          kind: :blocked_work,
          ref: episode.key,
          title: episode.key,
          updated_at: turn.updated_at
        }
      )
    )
  end

  defp publication_attention(prefix) do
    Repo.all(
      from(publication in Publication,
        where:
          publication.destination_transport == "slack" and
            like(publication.destination_conversation_ref, ^prefix) and
            publication.status in [:review_ready, :reviewed, :blocked],
        order_by: [desc: publication.updated_at, desc: publication.id],
        limit: ^@maximum_attention,
        select: %{
          kind: publication.status,
          ref: publication.ref,
          title: publication.title,
          updated_at: publication.updated_at
        }
      )
    )
  end

  defp incident_attention(workspace_ref) do
    Repo.all(
      from(room in IncidentRoom,
        where: room.workspace_ref == ^workspace_ref and room.status == :blocked,
        order_by: [desc: room.updated_at, desc: room.id],
        limit: ^@maximum_attention,
        select: %{
          kind: :blocked_incident,
          ref: room.ref,
          title: room.title,
          updated_at: room.updated_at
        }
      )
    )
  end

  defp work(prefix) do
    Repo.all(
      from(episode in Episode,
        left_join: turn in Turn,
        on:
          turn.episode_id == episode.id and episode.owner_kind == :turn and
            turn.turn_ref == episode.owner_ref,
        where:
          episode.destination_transport == "slack" and
            like(episode.destination_conversation_ref, ^prefix) and
            episode.state in ^@active_episode_states,
        order_by: [desc: episode.updated_at, desc: episode.id],
        limit: ^@maximum_work,
        select: {episode, turn.status, turn.coop_turn_id}
      )
    )
    |> Enum.map(fn {episode, turn_status, coop_turn_id} ->
      %{
        next_action: next_action(episode, turn_status, coop_turn_id),
        ref: episode.key,
        state: episode.state,
        title: episode.key
      }
    end)
  end

  defp incidents(workspace_ref) do
    Repo.all(
      from(room in IncidentRoom,
        where: room.workspace_ref == ^workspace_ref and room.status != :closed,
        order_by: [desc: room.updated_at, desc: room.id],
        limit: ^@maximum_incidents,
        select: %{
          channel_ref: room.channel_ref,
          ref: room.ref,
          status: room.status,
          title: room.title
        }
      )
    )
  end

  defp behaviors(workspace_ref, actor_ref, now) do
    visibility = home_behavior_visibility(actor_ref)

    Repo.all(
      from(behavior in Behavior,
        where:
          behavior.workspace_ref == ^workspace_ref and behavior.status in [:active, :disabled] and
            (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
        where: ^visibility,
        order_by: [desc: behavior.updated_at, desc: behavior.id],
        limit: ^@maximum_behaviors,
        select: %{
          kind: behavior.kind,
          ref: behavior.ref,
          status: behavior.status,
          subject: behavior.identity_key
        }
      )
    )
  end

  defp home_behavior_visibility(actor_ref) do
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

  defp memories(workspace_ref, now) do
    Repo.all(
      from(memory in MemoryEntry,
        where:
          memory.workspace_ref == ^workspace_ref and memory.status == :active and
            memory.expires_at > ^now and memory.visibility == :workspace and
            memory.scope_kind in [:repository, :workspace],
        order_by: [desc: memory.updated_at, desc: memory.id],
        limit: ^@maximum_memories,
        select: %{kind: memory.kind, ref: memory.ref, subject: memory.subject}
      )
    )
  end

  defp schedules(prefix, now) do
    Repo.all(
      from(schedule in Schedule,
        where:
          schedule.destination_transport == "slack" and
            like(schedule.destination_conversation_ref, ^prefix) and
            schedule.status in [:active, :paused] and
            (is_nil(schedule.expires_at) or schedule.expires_at > ^now),
        order_by: [asc: schedule.next_occurrence_at, asc: schedule.id],
        limit: ^@maximum_schedules,
        select: %{
          next_occurrence_at: schedule.next_occurrence_at,
          ref: schedule.ref,
          status: schedule.status,
          title: schedule.title
        }
      )
    )
  end

  defp next_action(%Episode{state: :waiting_for_input}, _turn_status, _coop_turn_id),
    do: "operator_input"

  defp next_action(%Episode{state: :waiting_for_event}, _turn_status, _coop_turn_id),
    do: "external_event"

  defp next_action(%Episode{owner_kind: :delivery}, _turn_status, _coop_turn_id),
    do: "deliver_result"

  defp next_action(_episode, :blocked, _coop_turn_id), do: "operator_recovery"
  defp next_action(_episode, :cancel_pending, _coop_turn_id), do: "reconcile_stop"
  defp next_action(_episode, _turn_status, nil), do: "start_work"
  defp next_action(_episode, _turn_status, _coop_turn_id), do: "continue_work"

  defp count(query), do: Repo.aggregate(query, :count, :id)

  defp database_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp workspace_ref?(value) do
    is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value) and byte_size(value) <= 256
  end

  defp actor_ref?(value) do
    is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value) and byte_size(value) <= 256
  end
end
