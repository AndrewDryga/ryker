defmodule Ryker.Memories.MemoryEntry.Query do
  @moduledoc "Facts people confirmed, for every read of `operational_memory_entries`."
  import Ecto.Query
  alias Ryker.Memories.MemoryEntry

  def all, do: from(entries in MemoryEntry, as: :operational_memory_entries)

  @doc "The fact a person's answer to question `question_ref` saved."
  def answering(question_ref) do
    where(
      all(),
      [operational_memory_entries: m],
      fragment(
        "? IS NOT NULL AND pg_input_is_valid(?, 'jsonb') AND (?::jsonb ->> 'question_ref') = ?",
        m.answer_provenance,
        m.answer_provenance,
        m.answer_provenance,
        ^question_ref
      )
    )
  end

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [operational_memory_entries: m], m.id in ^ids)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [operational_memory_entries: m], m.ref == ^ref)

  def by_refs(queryable \\ all(), refs),
    do: where(queryable, [operational_memory_entries: m], m.ref in ^refs)

  def by_offer_record_id(queryable \\ all(), record_id),
    do: where(queryable, [operational_memory_entries: m], m.offer_record_id == ^record_id)

  def by_confirmation_ref(queryable \\ all(), confirmation_ref),
    do: where(queryable, [operational_memory_entries: m], m.confirmation_ref == ^confirmation_ref)

  def by_workspace(queryable \\ all(), workspace_ref),
    do: where(queryable, [operational_memory_entries: m], m.workspace_ref == ^workspace_ref)

  def by_status(queryable, status),
    do: where(queryable, [operational_memory_entries: m], m.status == ^status)

  def scoped_to(queryable, scope_kind, scope_ref) do
    where(
      queryable,
      [operational_memory_entries: m],
      m.scope_kind == ^scope_kind and m.scope_ref == ^scope_ref
    )
  end

  @doc """
  Facts `context` may see: of its workspace, scoped to its conversation, its
  workspace or its repository and visible there, or global facts.
  """
  def visible_to(queryable, context) do
    scoped = scoped(context)

    # A dynamic can only be interpolated at the top of a `where`, so the rule
    # is built as one and applied whole.
    visible =
      dynamic(
        [operational_memory_entries: m],
        (m.visibility == :conversation and
           m.source_conversation_ref == ^context.conversation_ref and ^scoped) or
          (m.visibility == :workspace and ^scoped) or
          (m.visibility == :global and m.scope_kind == :global)
      )

    where(queryable, ^visible)
  end

  # An entry is in scope when it belongs to this workspace and its scope names
  # this conversation, this workspace, or the repository this session runs in.
  defp scoped(context) do
    kinds =
      dynamic(
        [operational_memory_entries: m],
        (m.scope_kind == :conversation and m.scope_ref == ^context.conversation_ref) or
          (m.scope_kind == :workspace and m.scope_ref == ^context.workspace_ref)
      )

    kinds =
      if is_binary(context.repository) do
        dynamic(
          [operational_memory_entries: m],
          ^kinds or (m.scope_kind == :repository and m.scope_ref == ^context.repository)
        )
      else
        kinds
      end

    dynamic([operational_memory_entries: m], m.workspace_ref == ^context.workspace_ref and ^kinds)
  end

  @doc """
  Active, unexpired facts `context` may search: of its workspace or global,
  and visible to the whole workspace, to everyone, or to its own conversation.
  """
  def searchable(context) do
    from(m in all(),
      where:
        (m.workspace_ref == ^context.workspace_ref or m.scope_kind == :global) and
          m.status == :active and
          (is_nil(m.expires_at) or m.expires_at > fragment("clock_timestamp()")),
      where:
        m.visibility in [:workspace, :global] or
          (m.visibility == :conversation and
             m.source_conversation_ref == ^context.conversation_ref)
    )
  end

  @doc "Facts in the scope a memory search names: this channel, the repository, the workspace or global."
  def in_search_scope(queryable, context, "current_channel"),
    do: scoped_to(queryable, :conversation, context.conversation_ref)

  def in_search_scope(queryable, %{repository: repository}, "repository")
      when is_binary(repository),
      do: scoped_to(queryable, :repository, repository)

  def in_search_scope(queryable, context, "workspace"),
    do: scoped_to(queryable, :workspace, context.workspace_ref)

  def in_search_scope(queryable, _context, "global"),
    do: where(queryable, [operational_memory_entries: m], m.scope_kind == :global)

  def in_search_scope(queryable, _context, _scope), do: where(queryable, false)

  @doc "The fields a memory search reads from a fact (`Ryker.Memories.SearchPage.Query`)."
  def search_fields do
    %{
      conversation: dynamic([operational_memory_entries: m], m.source_conversation_ref),
      thread: dynamic([operational_memory_entries: m], m.source_thread_ref),
      message: dynamic([operational_memory_entries: m], m.source_message_ref),
      text:
        dynamic([operational_memory_entries: m], fragment("? || ' ' || ?", m.subject, m.payload)),
      changed:
        dynamic(
          [operational_memory_entries: m],
          type(fragment("COALESCE(?, ?)", m.edited_at, m.confirmed_at), :utc_datetime_usec)
        ),
      source: dynamic([operational_memory_entries: m], m.confirmed_at)
    }
  end

  @doc "Each of `entries` exactly as it was read: the same row with the same content."
  def unchanged(queryable \\ all(), entries) do
    condition =
      Enum.reduce(entries, dynamic(false), fn entry, condition ->
        dynamic(
          [operational_memory_entries: m],
          ^condition or
            (m.id == ^entry.id and m.payload_fingerprint == ^entry.payload_fingerprint)
        )
      end)

    where(queryable, ^condition)
  end

  @doc "When each fact was last said first: edited, else confirmed, else saved."
  def ordered_by_recent_content(queryable) do
    order_by(queryable, [operational_memory_entries: m],
      desc: fragment("COALESCE(?, ?, ?)", m.edited_at, m.confirmed_at, m.inserted_at),
      desc: m.id
    )
  end

  def select_ids(queryable), do: select(queryable, [operational_memory_entries: m], m.id)

  @doc "Facts about the same subject as `memory`: one workspace, scope, kind and subject."
  def same_subject(queryable \\ all(), memory) do
    where(
      queryable,
      [operational_memory_entries: m],
      m.workspace_ref == ^memory.workspace_ref and m.scope_kind == ^memory.scope_kind and
        m.scope_ref == ^memory.scope_ref and m.kind == ^memory.kind and
        m.subject == ^memory.subject
    )
  end

  @doc "Confirmed, edited or deleted after `at`."
  def changed_after(queryable, at) do
    where(
      queryable,
      [operational_memory_entries: m],
      fragment(
        "GREATEST(?, ?, CASE WHEN ? = 'deleted' THEN ? END) > ?",
        m.confirmed_at,
        m.edited_at,
        m.status,
        m.updated_at,
        type(^at, :utc_datetime_usec)
      )
    )
  end

  @doc """
  Active global facts confirmed by answering in message `message_ref`, as it
  stood before `revision`: what a later edit or deletion of it takes back.
  """
  def answered_before_revision(transport, conversation_ref, message_ref, revision) do
    where(
      all(),
      [operational_memory_entries: m],
      m.scope_kind == :global and m.status == :active and m.source_transport == ^transport and
        m.source_conversation_ref == ^conversation_ref and m.source_message_ref == ^message_ref and
        fragment("(?::jsonb->>'source_revision')::bigint", m.answer_provenance) < ^revision
    )
  end

  @doc """
  Active facts a Slack channel's deletion takes: the ones only conversation
  `conversation_ref` of `workspace_ref` could see (scoped to it, or confirmed
  there and visible only there), and the global facts answered from a
  message in it. Facts the whole workspace may see outlive the channel they
  were confirmed in.
  """
  def bound_to_conversation(workspace_ref, conversation_ref) do
    where(
      all(),
      [operational_memory_entries: m],
      m.status == :active and
        ((m.workspace_ref == ^workspace_ref and m.scope_kind == :conversation and
            m.scope_ref == ^conversation_ref) or
           (m.workspace_ref == ^workspace_ref and m.visibility == :conversation and
              m.source_conversation_ref == ^conversation_ref) or
           (m.scope_kind == :global and m.source_conversation_ref == ^conversation_ref))
    )
  end

  # By the database's clock as the statement runs.
  def unexpired(queryable) do
    where(
      queryable,
      [operational_memory_entries: m],
      is_nil(m.expires_at) or m.expires_at > fragment("clock_timestamp()")
    )
  end

  def unexpired_at(queryable, now) do
    where(
      queryable,
      [operational_memory_entries: m],
      is_nil(m.expires_at) or m.expires_at > ^now
    )
  end

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [operational_memory_entries: m], desc: m.updated_at, desc: m.id)

  def ordered_by_least_recently_updated(queryable),
    do: order_by(queryable, [operational_memory_entries: m], asc: m.updated_at, asc: m.id)

  def ordered_by_ref(queryable),
    do: order_by(queryable, [operational_memory_entries: m], asc: m.ref)

  def select_distinct_workspace_refs(queryable) do
    queryable
    |> distinct(true)
    |> select([operational_memory_entries: m], m.workspace_ref)
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def active(queryable \\ all()),
    do: where(queryable, [operational_memory_entries: m], m.status == :active)

  @doc "Facts that have not expired by the database clock."
  def unexpired_now(queryable) do
    where(
      queryable,
      [operational_memory_entries: m],
      is_nil(m.expires_at) or m.expires_at > fragment("clock_timestamp()")
    )
  end

  @doc "Facts whose subject, value or applicability says `text`, whatever the case."
  def saying(queryable, text) do
    where(
      queryable,
      [operational_memory_entries: m],
      fragment(
        "position(lower(?) in lower(concat_ws(' ', ?, ?::jsonb->>'value', ?::jsonb->>'applicability'))) > 0",
        ^text,
        m.subject,
        m.payload,
        m.payload
      )
    )
  end

  @doc "Each fact as the Facts page lists it."
  def select_facts(queryable) do
    select(queryable, [operational_memory_entries: m], %{
      kind: m.kind,
      ref: m.ref,
      scope: m.scope_kind,
      scope_ref: m.scope_ref,
      applicability: fragment("?::jsonb->>'applicability'", m.payload),
      value: fragment("?::jsonb->>'value'", m.payload),
      status: m.status,
      subject: m.subject,
      recall_count: m.recall_count,
      confirmed_at: m.confirmed_at
    })
  end

  def confirmed_between(queryable, from, to) do
    where(
      queryable,
      [operational_memory_entries: m],
      m.confirmed_at >= ^from and m.confirmed_at < ^to
    )
  end
end
