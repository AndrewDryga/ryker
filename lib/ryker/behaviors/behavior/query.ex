defmodule Ryker.Behaviors.Behavior.Query do
  @moduledoc """
  Confirmed guidance, preferences and standing assignments, for every read of
  `operator_behaviors`.
  """
  import Ecto.Query
  alias Ryker.Behaviors.Behavior

  def all, do: from(behaviors in Behavior, as: :operator_behaviors)

  def by_id(queryable \\ all(), id), do: where(queryable, [operator_behaviors: b], b.id == ^id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [operator_behaviors: b], b.id in ^ids)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [operator_behaviors: b], b.ref == ^ref)

  def by_refs(queryable \\ all(), refs),
    do: where(queryable, [operator_behaviors: b], b.ref in ^refs)

  def by_offer_record_id(queryable \\ all(), record_id),
    do: where(queryable, [operator_behaviors: b], b.offer_record_id == ^record_id)

  def by_workspace(queryable \\ all(), workspace_ref),
    do: where(queryable, [operator_behaviors: b], b.workspace_ref == ^workspace_ref)

  def of_kind(queryable \\ all(), kind),
    do: where(queryable, [operator_behaviors: b], b.kind == ^kind)

  def by_kinds(queryable \\ all(), kinds),
    do: where(queryable, [operator_behaviors: b], b.kind in ^kinds)

  def by_status(queryable \\ all(), status)

  def by_status(queryable, statuses) when is_list(statuses),
    do: where(queryable, [operator_behaviors: b], b.status in ^statuses)

  def by_status(queryable, status),
    do: where(queryable, [operator_behaviors: b], b.status == ^status)

  def without_status(queryable \\ all(), statuses),
    do: where(queryable, [operator_behaviors: b], b.status not in ^statuses)

  def scoped_to(queryable \\ all(), scope_kind, scope_ref) do
    where(
      queryable,
      [operator_behaviors: b],
      b.scope_kind == ^scope_kind and b.scope_ref == ^scope_ref
    )
  end

  @doc "Scoped to any one of `scopes`, each a `{scope_kind, scope_ref}`."
  def in_any_scope(queryable, scopes) do
    condition =
      Enum.reduce(scopes, dynamic(false), fn {scope_kind, scope_ref}, condition ->
        dynamic(
          [operator_behaviors: b],
          ^condition or (b.scope_kind == ^scope_kind and b.scope_ref == ^scope_ref)
        )
      end)

    where(queryable, ^condition)
  end

  @doc "In the scope a memory search names: this channel, the repository, the workspace or mine."
  def in_search_scope(queryable, context, "current_channel"),
    do: scoped_to(queryable, :conversation, context.conversation_ref)

  def in_search_scope(queryable, %{repository: repository}, "repository")
      when is_binary(repository),
      do: scoped_to(queryable, :repository, repository)

  def in_search_scope(queryable, context, "workspace"),
    do: scoped_to(queryable, :workspace, context.workspace_ref)

  def in_search_scope(queryable, %{operator_ref: operator}, "mine") when is_binary(operator),
    do: scoped_to(queryable, :operator, operator)

  def in_search_scope(queryable, _context, _scope), do: where(queryable, false)

  @doc """
  What the turn answering `context` may read of `kind`: a person's private
  guidance is theirs alone, and a turn answering nobody in particular reads
  the rest.
  """
  def visible_to(queryable, :guidance, %{operator_ref: nil} = context) do
    where(
      queryable,
      [operator_behaviors: b],
      fragment("(?::jsonb)->>'visibility'", b.payload) == "workspace" or
        (fragment("(?::jsonb)->>'visibility'", b.payload) == "conversation" and
           b.source_conversation_ref == ^context.conversation_ref)
    )
  end

  def visible_to(queryable, :guidance, context) do
    where(
      queryable,
      [operator_behaviors: b],
      fragment("(?::jsonb)->>'visibility'", b.payload) == "workspace" or
        (b.scope_kind == :operator and
           fragment("(?::jsonb)->>'visibility'", b.payload) == "private" and
           b.scope_ref == ^context.operator_ref) or
        (fragment("(?::jsonb)->>'visibility' IN ('conversation', 'private')", b.payload) and
           b.source_conversation_ref == ^context.conversation_ref)
    )
  end

  def visible_to(queryable, _kind, _context), do: queryable

  @doc "The behaviors that would replace one with the same identity as `behavior`."
  def same_identity(queryable \\ all(), behavior) do
    where(
      queryable,
      [operator_behaviors: b],
      b.kind == ^behavior.kind and b.workspace_ref == ^behavior.workspace_ref and
        b.scope_kind == ^behavior.scope_kind and b.scope_ref == ^behavior.scope_ref and
        b.identity_key == ^behavior.identity_key
    )
  end

  @doc "Each of `behaviors` still as it was read: same payload, same revision."
  def unchanged(queryable \\ all(), behaviors) do
    condition =
      Enum.reduce(behaviors, dynamic(false), fn behavior, condition ->
        dynamic(
          [operator_behaviors: b],
          ^condition or
            (b.id == ^behavior.id and b.payload == ^behavior.payload and
               b.revision == ^behavior.revision)
        )
      end)

    where(queryable, ^condition)
  end

  @doc """
  The behaviors of `workspace_ref` that only conversation `conversation_ref`
  could see: scoped to it, or learned there and visible only there.
  """
  def bound_to_conversation(workspace_ref, conversation_ref) do
    where(
      all(),
      [operator_behaviors: b],
      b.workspace_ref == ^workspace_ref and
        ((b.scope_kind == :conversation and b.scope_ref == ^conversation_ref) or
           (b.source_conversation_ref == ^conversation_ref and
              fragment("?::jsonb->>'visibility' = 'conversation'", b.payload)))
    )
  end

  def unexpired_at(queryable, now),
    do: where(queryable, [operator_behaviors: b], is_nil(b.expires_at) or b.expires_at > ^now)

  # By the database's clock as the statement runs, as retrieval reads it.
  def unexpired(queryable) do
    where(
      queryable,
      [operator_behaviors: b],
      is_nil(b.expires_at) or b.expires_at > fragment("clock_timestamp()")
    )
  end

  @doc "The fields a memory search reads from a behavior (`Ryker.Memories.MemorySearchPage`)."
  def search_fields do
    %{
      conversation: dynamic([operator_behaviors: b], b.source_conversation_ref),
      thread: dynamic([operator_behaviors: b], b.source_thread_ref),
      message: dynamic([operator_behaviors: b], b.source_message_ref),
      text: dynamic([operator_behaviors: b], b.payload),
      changed:
        dynamic(
          [operator_behaviors: b],
          type(fragment("COALESCE(?, ?)", b.edited_at, b.confirmed_at), :utc_datetime_usec)
        ),
      source: dynamic([operator_behaviors: b], b.confirmed_at)
    }
  end

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [operator_behaviors: b], asc: b.inserted_at, asc: b.id)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [operator_behaviors: b], desc: b.updated_at, desc: b.id)

  def ordered_by_least_recently_updated(queryable),
    do: order_by(queryable, [operator_behaviors: b], asc: b.updated_at, asc: b.id)

  def ordered_by_ref(queryable), do: order_by(queryable, [operator_behaviors: b], asc: b.ref)

  def select_distinct_workspace_refs(queryable) do
    queryable
    |> distinct(true)
    |> select([operator_behaviors: b], b.workspace_ref)
  end

  # The narrowest scope first: a person's own, then the channel's, the
  # repository's and the workspace's.
  def ordered_by_scope_precedence(queryable) do
    order_by(queryable, [operator_behaviors: b],
      asc:
        fragment(
          "CASE ? WHEN 'operator' THEN 0 WHEN 'conversation' THEN 1 WHEN 'repository' THEN 2 WHEN 'workspace' THEN 3 ELSE 4 END",
          b.scope_kind
        ),
      desc: b.updated_at,
      desc: b.id
    )
  end

  def ordered_by_id(queryable), do: order_by(queryable, [operator_behaviors: b], asc: b.id)
  def select_ids(queryable), do: select(queryable, [operator_behaviors: b], b.id)
  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
end
