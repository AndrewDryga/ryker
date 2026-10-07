defmodule Ryker.ControlPlane.ChannelContext.Query do
  @moduledoc """
  What a Slack channel's page reads of the context Ryker keeps for it
  (`Ryker.ControlPlane.ChannelContext`): the rules, preferences, guidance and
  memory that apply there, its summaries, drafts, unsaved handovers and
  learned topics. Every read keys on the channel's canonical refs
  (`Ryker.ControlPlane.ChannelScope`).
  """
  import Ecto.Query
  alias Ryker.Behaviors.Behavior
  alias Ryker.Continuity.{ConversationSummary, ConversationSummaryDraft}
  alias Ryker.ControlPlane.ChannelScope
  alias Ryker.Episodes.Episode
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Work.Turn

  @doc """
  Standing rules that target exactly this conversation and are current,
  paused ones included.
  """
  def rules(scope) do
    from(behavior in Behavior,
      where:
        behavior.kind == :standing_assignment and
          behavior.workspace_ref == ^scope.canonical_workspace_ref and
          behavior.scope_kind == :conversation and
          behavior.scope_ref == ^scope.conversation_ref and
          behavior.status in [:active, :disabled] and
          (is_nil(behavior.expires_at) or behavior.expires_at > fragment("clock_timestamp()"))
    )
  end

  @doc """
  Active, unexpired behaviors of `kind` effective here through exact,
  repository or workspace scope.
  """
  def effective_behaviors(kind, scope) do
    from([operator_behaviors: behavior] in Behavior.Query.all(),
      where:
        behavior.kind == ^kind and behavior.status == :active and
          behavior.workspace_ref == ^scope.canonical_workspace_ref and
          (is_nil(behavior.expires_at) or behavior.expires_at > fragment("clock_timestamp()")),
      where: ^scoped(scope, :operator_behaviors)
    )
  end

  @doc """
  Guidance recalled here: guidance visible to the workspace, or to the
  conversation (or privately) when this conversation confirmed it.
  """
  def recalled_guidance(scope) do
    :guidance
    |> effective_behaviors(scope)
    |> where(
      [operator_behaviors: b],
      fragment("(?::jsonb)->>'visibility'", b.payload) == "workspace" or
        (fragment("(?::jsonb)->>'visibility' IN ('conversation', 'private')", b.payload) and
           b.source_conversation_ref == ^scope.conversation_ref)
    )
  end

  @doc """
  Active, unexpired memory the runtime would recall here: global facts,
  workspace-visible entries of its scope, and conversation-visible ones this
  conversation confirmed.
  """
  def memory(scope) do
    from([operational_memory_entries: entry] in MemoryEntry.Query.all(),
      where:
        entry.status == :active and
          (is_nil(entry.expires_at) or entry.expires_at > fragment("clock_timestamp()")),
      where: ^memory_scope(scope),
      where:
        entry.visibility in [:workspace, :global] or
          (entry.visibility == :conversation and
             entry.source_conversation_ref == ^scope.conversation_ref)
    )
  end

  defp memory_scope(scope) do
    dynamic(
      [operational_memory_entries: m],
      m.scope_kind == :global or
        (m.workspace_ref == ^scope.canonical_workspace_ref and
           ^scoped(scope, :operational_memory_entries))
    )
  end

  # Exact conversation, the repository the channel's environment changes
  # when there is one, or the workspace. Operator scope needs an actor
  # context the page does not have. Behaviors and memory entries share these
  # scope columns, so the caller names the binding the rows are read through.
  defp scoped(%ChannelScope{repository_ref: repository} = scope, binding)
       when is_binary(repository) do
    dynamic(
      [{^binding, row}],
      (row.scope_kind == :conversation and row.scope_ref == ^scope.conversation_ref) or
        (row.scope_kind == :repository and row.scope_ref == ^repository) or
        (row.scope_kind == :workspace and row.scope_ref == ^scope.canonical_workspace_ref)
    )
  end

  defp scoped(scope, binding) do
    dynamic(
      [{^binding, row}],
      (row.scope_kind == :conversation and row.scope_ref == ^scope.conversation_ref) or
        (row.scope_kind == :workspace and row.scope_ref == ^scope.canonical_workspace_ref)
    )
  end

  @doc """
  Most specific scope first, as the runtime resolves precedence; then newest.
  `binding` names the rows: `:operator_behaviors` or `:operational_memory_entries`.
  """
  def inherited_order(binding) do
    [
      asc:
        dynamic(
          [{^binding, row}],
          fragment(
            "CASE ? WHEN 'conversation' THEN 0 WHEN 'repository' THEN 1 WHEN 'workspace' THEN 2 ELSE 3 END",
            row.scope_kind
          )
        ),
      desc: :updated_at,
      desc: :id
    ]
  end

  @doc "This conversation's durable summaries."
  def summaries(scope) do
    from(summary in ConversationSummary,
      where:
        summary.transport == "slack" and
          summary.workspace_ref == ^scope.canonical_workspace_ref and
          summary.conversation_ref == ^scope.conversation_ref
    )
  end

  @doc "Summary drafts of requests answered in this conversation."
  def summary_drafts(scope) do
    from(draft in ConversationSummaryDraft,
      join: episode in Episode,
      on: episode.id == draft.episode_id,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref == ^scope.conversation_ref
    )
  end

  @doc "Accepted answers in this conversation whose summary could not be saved."
  def failed_handovers(scope) do
    from(turn in Turn,
      join: episode in Episode,
      on: episode.id == turn.episode_id,
      where:
        not is_nil(turn.summary_error_code) and episode.destination_transport == "slack" and
          episode.destination_conversation_ref == ^scope.conversation_ref
    )
  end

  @doc "Topics learned in exactly this conversation."
  def knowledge(scope) do
    from(item in ConversationKnowledge,
      where:
        item.transport == "slack" and
          item.workspace_ref == ^scope.canonical_workspace_ref and
          item.conversation_ref == ^scope.conversation_ref
    )
  end
end
