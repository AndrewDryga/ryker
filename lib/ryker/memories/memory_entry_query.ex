defmodule Ryker.Memories.MemoryEntryQuery do
  @moduledoc "Facts people confirmed, for every read of `operational_memory_entries`."
  import Ecto.Query
  alias Ryker.Memories.MemoryEntry

  def all, do: from(entries in MemoryEntry, as: :operational_memory_entries)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [operational_memory_entries: m], m.ref == ^ref)

  def by_offer_record_id(queryable \\ all(), record_id),
    do: where(queryable, [operational_memory_entries: m], m.offer_record_id == ^record_id)

  def by_confirmation_ref(queryable \\ all(), confirmation_ref),
    do: where(queryable, [operational_memory_entries: m], m.confirmation_ref == ^confirmation_ref)

  def by_workspace(queryable \\ all(), workspace_ref),
    do: where(queryable, [operational_memory_entries: m], m.workspace_ref == ^workspace_ref)

  def with_status(queryable, status),
    do: where(queryable, [operational_memory_entries: m], m.status == ^status)

  def scoped_to(queryable, scope_kind, scope_ref) do
    where(
      queryable,
      [operational_memory_entries: m],
      m.scope_kind == ^scope_kind and m.scope_ref == ^scope_ref
    )
  end

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

  def unexpired_at(queryable, now) do
    where(
      queryable,
      [operational_memory_entries: m],
      is_nil(m.expires_at) or m.expires_at > ^now
    )
  end

  def recently_updated_first(queryable),
    do: order_by(queryable, [operational_memory_entries: m], desc: m.updated_at, desc: m.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def active(queryable \\ all()),
    do: where(queryable, [operational_memory_entries: m], m.status == :active)

  def confirmed_between(queryable, from, to) do
    where(
      queryable,
      [operational_memory_entries: m],
      m.confirmed_at >= ^from and m.confirmed_at < ^to
    )
  end
end
