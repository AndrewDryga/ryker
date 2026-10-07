defmodule Ryker.Continuity.ConversationRollup.Query do
  @moduledoc "Rollups of earlier summaries, for every read of `conversation_rollups`."
  import Ecto.Query
  alias Ryker.Continuity.ConversationRollup

  def all, do: from(rollups in ConversationRollup, as: :conversation_rollups)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [conversation_rollups: r], r.id == ^id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [conversation_rollups: r], r.id in ^ids)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [conversation_rollups: r], r.ref == ^ref)

  def in_workspace(queryable \\ all(), workspace_ref),
    do: where(queryable, [conversation_rollups: r], r.workspace_ref == ^workspace_ref)

  @doc "The rollup of one scope's week."
  def by_identity(workspace_ref, scope_kind, scope_ref, period_start) do
    where(
      all(),
      [conversation_rollups: r],
      r.workspace_ref == ^workspace_ref and r.scope_kind == ^scope_kind and
        r.scope_ref == ^scope_ref and r.period_start == ^period_start
    )
  end

  @doc """
  Unexpired rollups of `context`'s workspace: its conversation's, and, with a
  repository, that repository's.
  """
  def for_context(%{repository_ref: repository_ref} = context) when is_binary(repository_ref) do
    where(
      all(),
      [conversation_rollups: r],
      r.workspace_ref == ^context.workspace_ref and r.expires_at > fragment("clock_timestamp()") and
        ((r.scope_kind == :conversation and r.scope_ref == ^context.conversation_ref) or
           (r.scope_kind == :repository and r.repository_ref == ^repository_ref))
    )
  end

  def for_context(context) do
    where(
      all(),
      [conversation_rollups: r],
      r.workspace_ref == ^context.workspace_ref and r.expires_at > fragment("clock_timestamp()") and
        r.scope_kind == :conversation and r.scope_ref == ^context.conversation_ref
    )
  end

  @doc """
  Rollups `context` may read: its conversation's, and, from a public channel
  with a repository, that repository's public rollups whose every source is
  still a joined public Slack channel.
  """
  def visible_to(queryable, %{visibility: :public, repository_ref: repository_ref} = context)
      when is_binary(repository_ref) do
    where(
      queryable,
      [conversation_rollups: r],
      (r.scope_kind == :conversation and r.scope_ref == ^context.conversation_ref) or
        (r.scope_kind == :repository and r.repository_ref == ^repository_ref and
           r.visibility == :public and
           fragment(
             """
             NOT EXISTS (
               SELECT 1 FROM jsonb_array_elements(COALESCE(?::jsonb, '[]'::jsonb)) source_scope
               LEFT JOIN slack_channel_memberships membership
                 ON membership.workspace_ref = source_scope->>'workspace_ref'
                AND membership.channel_ref = source_scope->>'channel_ref'
               WHERE source_scope->>'transport' IS DISTINCT FROM 'slack'
                  OR membership.workspace_ref IS NULL
                  OR membership.status IS DISTINCT FROM 'joined'
                  OR membership.private IS DISTINCT FROM false
                  OR membership.external_shared IS DISTINCT FROM false
             )
             """,
             r.source_scopes
           ))
    )
  end

  def visible_to(queryable, context) do
    where(
      queryable,
      [conversation_rollups: r],
      r.scope_kind == :conversation and r.scope_ref == ^context.conversation_ref
    )
  end

  @doc "Rollups within the scope a search names: this channel, the repository or the workspace."
  def within_scope(queryable, context, "current_channel") do
    where(
      queryable,
      [conversation_rollups: r],
      r.scope_kind == :conversation and r.scope_ref == ^context.conversation_ref
    )
  end

  def within_scope(queryable, %{repository_ref: repository_ref}, "repository")
      when is_binary(repository_ref),
      do: where(queryable, [conversation_rollups: r], r.repository_ref == ^repository_ref)

  def within_scope(queryable, _context, "workspace"), do: queryable
  def within_scope(queryable, _context, _scope), do: where(queryable, false)

  def latest_period_first(queryable),
    do: order_by(queryable, [conversation_rollups: r], desc: r.period_end, desc: r.id)

  @doc "The fields a memory search reads from a rollup (`Ryker.Memories.SearchPage.Query`)."
  def search_fields(source) do
    %{
      text: dynamic([conversation_rollups: r], r.state),
      changed: dynamic([conversation_rollups: r], r.updated_at),
      source: source
    }
  end

  def select_ids(queryable), do: select(queryable, [conversation_rollups: r], r.id)
  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
