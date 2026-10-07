defmodule Ryker.Slack.Collection.Query do
  @moduledoc """
  What a Slack channel's saved collections list (`Ryker.Slack.Collections`):
  its schedules, its standing rules, and the knowledge it may see, each a
  page at a time by the database clock `now`. `conversation_refs` are the
  channel's Slack conversation refs.
  """
  import Ecto.Query
  alias Ryker.Behaviors.Behavior
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Schedules.Schedule

  @doc "Every item of collection `kind` (`:schedules` or `:standing_rules`) of the channel."
  def items(:schedules, _workspace_ref, conversation_refs, now) do
    from(schedule in Schedule,
      where:
        schedule.destination_transport == "slack" and
          schedule.destination_conversation_ref in ^conversation_refs and
          schedule.status in [:active, :paused] and
          (is_nil(schedule.expires_at) or schedule.expires_at > ^now)
    )
  end

  def items(:standing_rules, workspace_ref, conversation_refs, now) do
    from(behavior in Behavior,
      where:
        behavior.kind == :standing_assignment and
          behavior.workspace_ref == ^"slack:#{workspace_ref}" and
          behavior.scope_kind == :conversation and
          behavior.scope_ref in ^conversation_refs and
          behavior.status in [:active, :disabled] and
          (is_nil(behavior.expires_at) or behavior.expires_at > ^now)
    )
  end

  @doc "One page of collection `kind`: schedules soonest first, standing rules latest first."
  def page(:schedules, workspace_ref, conversation_refs, now, offset, limit) do
    from(schedule in items(:schedules, workspace_ref, conversation_refs, now),
      order_by: [asc: schedule.next_occurrence_at, asc: schedule.inserted_at, asc: schedule.id],
      offset: ^offset,
      limit: ^limit
    )
  end

  def page(:standing_rules, workspace_ref, conversation_refs, now, offset, limit) do
    from(behavior in items(:standing_rules, workspace_ref, conversation_refs, now),
      order_by: [desc: behavior.updated_at, desc: behavior.id],
      offset: ^offset,
      limit: ^limit
    )
  end

  @doc """
  Guidance and preferences the channel may see: its own, and the
  workspace's and repositories'. Operator-scoped (private) guidance belongs
  to one person and is never listed for a channel.
  """
  def knowledge_behaviors(slack_workspace, conversation_refs, now) do
    from(behavior in Behavior,
      where:
        behavior.kind in [:preference, :guidance] and
          behavior.workspace_ref == ^slack_workspace and
          ((behavior.scope_kind == :conversation and
              behavior.scope_ref in ^conversation_refs) or
             behavior.scope_kind in [:workspace, :repository]) and
          behavior.status in [:active, :disabled] and
          (is_nil(behavior.expires_at) or behavior.expires_at > ^now)
    )
  end

  @doc "Facts the channel may see: its own, and those the whole workspace may see."
  def knowledge_memories(slack_workspace, conversation_refs, now) do
    from(memory in MemoryEntry,
      where:
        memory.workspace_ref == ^slack_workspace and memory.status == :active and
          (is_nil(memory.expires_at) or memory.expires_at > ^now) and
          ((memory.scope_kind == :conversation and memory.scope_ref in ^conversation_refs) or
             (memory.scope_kind in [:workspace, :repository] and
                memory.visibility == :workspace))
    )
  end

  @doc """
  One page of the channel's knowledge, latest changed first, as `%{kind:
  "behavior" | "memory", id: id, updated_at: at}` rows.
  """
  def knowledge_page(slack_workspace, conversation_refs, now, offset, limit) do
    memories =
      from(memory in knowledge_memories(slack_workspace, conversation_refs, now),
        select: %{kind: "memory", id: memory.id, updated_at: memory.updated_at}
      )

    newest =
      from(behavior in knowledge_behaviors(slack_workspace, conversation_refs, now),
        select: %{kind: "behavior", id: behavior.id, updated_at: behavior.updated_at},
        union_all: ^memories
      )

    from(item in subquery(newest),
      order_by: [desc: item.updated_at, desc: item.id],
      offset: ^offset,
      limit: ^limit
    )
  end
end
