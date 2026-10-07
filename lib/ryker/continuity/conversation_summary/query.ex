defmodule Ryker.Continuity.ConversationSummary.Query do
  @moduledoc "Summaries of earlier conversation, for every read of `conversation_summaries`."
  use Ryker, :query
  alias Ryker.Continuity.{ConversationRollup, ConversationSummary}
  alias Ryker.Learning.{SourceDependency, Visibility}
  alias Ryker.Slack.ChannelMembership

  def all, do: from(summaries in ConversationSummary, as: :conversation_summaries)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [conversation_summaries: s], s.id == ^id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [conversation_summaries: s], s.id in ^ids)

  def by_identity_key(queryable \\ all(), identity_key),
    do: where(queryable, [conversation_summaries: s], s.identity_key == ^identity_key)

  def excluding_identity_key(queryable, identity_key),
    do: where(queryable, [conversation_summaries: s], s.identity_key != ^identity_key)

  def by_conversation(queryable \\ all(), workspace_ref, conversation_ref) do
    where(
      queryable,
      [conversation_summaries: s],
      s.workspace_ref == ^workspace_ref and s.conversation_ref == ^conversation_ref
    )
  end

  @doc """
  The `count` oldest summaries a maintenance pass folds into rollups, locked:
  changed before `before`, not pruned, past any retry delay, with sources,
  and not in the week of a kept rollup that has none.
  """
  def compactable(before, count) do
    all()
    |> where(
      [conversation_summaries: s],
      s.updated_at < ^before and s.state != ^%{"retention" => "pruned"}
    )
    |> where(
      [conversation_summaries: s],
      is_nil(s.compaction_retry_at) or s.compaction_retry_at <= fragment("clock_timestamp()")
    )
    |> SourceDependency.Query.sourced()
    |> without_unsourced_rollup()
    |> order_by([conversation_summaries: s], asc: s.updated_at, asc: s.id)
    |> limit(^count)
    |> lock("FOR UPDATE")
  end

  defp without_unsourced_rollup(queryable) do
    # Match the rollup identity Compaction groups by before LIMIT so preserved
    # history cannot monopolize every maintenance pass. The locked group check
    # remains authoritative.
    repository_scope = repository_rollup_scope()

    matching_scope =
      dynamic(
        [conversation_rollups: r],
        (^repository_scope and r.scope_kind == :repository and
           r.scope_ref == parent_as(:conversation_summaries).repository_ref) or
          (not (^repository_scope) and r.scope_kind == :conversation and
             r.scope_ref == parent_as(:conversation_summaries).conversation_ref)
      )

    blocked =
      from([conversation_rollups: rollup] in ConversationRollup.Query.all(),
        where: rollup.workspace_ref == parent_as(:conversation_summaries).workspace_ref,
        where: rollup.state != ^%{"retention" => "pruned"},
        where:
          fragment(
            "CASE WHEN jsonb_typeof(?::jsonb) = 'array' THEN ?::jsonb = '[]'::jsonb ELSE true END",
            rollup.source_dependencies,
            rollup.source_dependencies
          ),
        where:
          rollup.period_start <= parent_as(:conversation_summaries).updated_at and
            fragment(
              "? < ? + interval '7 days'",
              parent_as(:conversation_summaries).updated_at,
              rollup.period_start
            ),
        where: ^matching_scope
      )

    where(queryable, not exists(subquery(blocked)))
  end

  defp repository_rollup_scope do
    memberships =
      from(membership in ChannelMembership,
        # The host splits a conversation into exactly transport/workspace/channel.
        # Colons can belong to the channel suffix, never the workspace component.
        where: fragment("position(':' in ?) = 0", membership.workspace_ref),
        where:
          fragment(
            "? = 'slack:' || ?",
            parent_as(:conversation_summaries).workspace_ref,
            membership.workspace_ref
          ),
        where:
          fragment(
            "? = 'slack:' || ? || ':' || ?",
            parent_as(:conversation_summaries).conversation_ref,
            membership.workspace_ref,
            membership.channel_ref
          ),
        where:
          membership.status == :joined and not membership.private and
            not membership.external_shared
      )

    dynamic(
      parent_as(:conversation_summaries).transport == "slack" and
        parent_as(:conversation_summaries).visibility == :public and
        not is_nil(parent_as(:conversation_summaries).repository_ref) and
        exists(subquery(memberships))
    )
  end

  @doc """
  Summaries `context` may search: of its workspace, readable from its
  conversation, and its own or a Slack channel's.
  """
  def searchable(context) do
    all()
    |> where([conversation_summaries: s], s.workspace_ref == ^context.workspace_ref)
    |> Visibility.Query.visible_from(context)
    |> where(
      [conversation_summaries: s],
      s.conversation_ref == ^context.conversation_ref or s.transport == "slack"
    )
  end

  @doc "Summaries within the scope a search names: this channel, the repository or the workspace."
  def within_scope(queryable, context, "current_channel") do
    where(
      queryable,
      [conversation_summaries: s],
      s.conversation_ref == ^context.conversation_ref
    )
  end

  def within_scope(queryable, %{repository_ref: repository_ref}, "repository")
      when is_binary(repository_ref),
      do: where(queryable, [conversation_summaries: s], s.repository_ref == ^repository_ref)

  def within_scope(queryable, _context, "workspace"), do: queryable
  def within_scope(queryable, _context, _scope), do: where(queryable, false)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [conversation_summaries: s], desc: s.updated_at, desc: s.id)

  @doc "The small fields a recall ranks summaries by, before it loads the few it keeps."
  def select_descriptors(queryable) do
    select(
      queryable,
      [conversation_summaries: s],
      map(s, [:id, :conversation_ref, :repository_ref, :updated_at, :ref, :state])
    )
  end

  @doc "The fields a memory search reads from a summary (`Ryker.Memories.SearchPage.Query`)."
  def search_fields(source) do
    %{
      text: dynamic([conversation_summaries: s], s.state),
      changed: dynamic([conversation_summaries: s], s.updated_at),
      source: source
    }
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
