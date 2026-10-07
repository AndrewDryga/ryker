defmodule Ryker.Ingress.Inbox.EntryQuery do
  @moduledoc "Recorded messages and events, for every read of `ingress_inbox_entries`."
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry

  def all, do: from(entries in Entry, as: :ingress_inbox_entries)

  def by_id(queryable \\ all(), id), do: where(queryable, [ingress_inbox_entries: e], e.id == ^id)

  def by_source_event(queryable \\ all(), source_kind, event_ref) do
    where(
      queryable,
      [ingress_inbox_entries: e],
      e.source_kind == ^source_kind and e.event_ref == ^event_ref
    )
  end

  def newest_first(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], desc: e.inserted_at)

  @doc "Earlier revisions of the message `entry` revises, oldest first, each with what a revision changes."
  def earlier_revisions_of(entry) do
    all()
    |> where(
      [ingress_inbox_entries: e],
      e.source_kind == ^entry.source_kind and e.source_ref == ^entry.source_ref and
        e.native_input_id == ^entry.native_input_id and
        e.execution_mode == ^entry.execution_mode and
        e.revision < ^entry.revision and e.id != ^entry.id
    )
    |> order_by([ingress_inbox_entries: e], asc: e.revision, asc: e.inserted_at, asc: e.id)
    |> select(
      [ingress_inbox_entries: e],
      struct(e, [:id, :actor_ref, :episode_id, :occurred_at, :revision, :event_kind])
    )
  end

  @doc """
  What the author of `entry` said earlier in its conversation, from `since`
  until `entry`, newest first and at most `limit`: messages and edits not
  pruned, each with what asking again compares.
  """
  def earlier_questions(entry, since, limit) do
    all()
    |> where(
      [ingress_inbox_entries: e],
      e.source_kind == ^entry.source_kind and e.source_ref == ^entry.source_ref and
        e.occurred_at >= ^since and e.occurred_at < ^entry.occurred_at
    )
    |> where(
      [ingress_inbox_entries: e],
      e.actor_kind == :user and e.actor_ref == ^entry.actor_ref
    )
    |> where(
      [ingress_inbox_entries: e],
      e.destination_transport == ^entry.destination_transport and
        e.destination_conversation_ref == ^entry.destination_conversation_ref and
        e.execution_mode == ^entry.execution_mode
    )
    |> where([ingress_inbox_entries: e], e.event_kind in [:message, :edit] and e.id != ^entry.id)
    |> where([ingress_inbox_entries: e], is_nil(e.operational_pruned_at))
    |> order_by([ingress_inbox_entries: e], desc: e.occurred_at, desc: e.id)
    |> limit(^limit)
    |> select(
      [ingress_inbox_entries: e],
      struct(e, [:id, :content, :episode_id, :occurred_at, :destination_thread_ref])
    )
  end

  @doc "Later revisions of the message `entry` revises."
  def later_revisions_of(entry) do
    where(
      all(),
      [ingress_inbox_entries: e],
      e.source_kind == ^entry.source_kind and e.source_ref == ^entry.source_ref and
        e.native_input_id == ^entry.native_input_id and e.revision > ^entry.revision
    )
  end

  @doc "A GitHub item Ryker already engaged with, by its repository and the item it is."
  def engaged_github_item(source_ref, source_item_ref) do
    where(
      all(),
      [ingress_inbox_entries: e],
      e.source_kind == "github" and e.source_ref == ^source_ref and
        e.source_item_ref == ^source_item_ref and not is_nil(e.engagement_receipt)
    )
  end

  @doc "Decided and still keeping its bodies."
  def decided_with_bodies(queryable) do
    where(
      queryable,
      [ingress_inbox_entries: e],
      e.status == :decided and is_nil(e.operational_pruned_at)
    )
  end

  @doc "Each message deleted in one of `conversation_refs`, as `{conversation, message}`."
  def deletions_in(conversation_refs) do
    all()
    |> where(
      [ingress_inbox_entries: e],
      e.event_kind == :delete and e.destination_conversation_ref in ^conversation_refs
    )
    |> select(
      [ingress_inbox_entries: e],
      {e.destination_conversation_ref,
       fragment("COALESCE(?, ?)", e.source_item_ref, e.native_input_id)}
    )
  end

  @doc """
  Every revision of each message in `conversation_refs` named by `message_refs`
  that someone edited, with the words of each revision.
  """
  def edit_histories(conversation_refs, message_refs) do
    from(edit in Entry,
      join: revision in Entry,
      on:
        revision.source_kind == edit.source_kind and revision.source_ref == edit.source_ref and
          revision.native_input_id == edit.native_input_id,
      where:
        edit.event_kind == :edit and edit.destination_conversation_ref in ^conversation_refs and
          fragment("COALESCE(?, ?)", edit.source_item_ref, edit.native_input_id) in ^message_refs,
      distinct: revision.id,
      select: %{
        id: revision.id,
        message:
          {edit.destination_conversation_ref,
           fragment("COALESCE(?, ?)", edit.source_item_ref, edit.native_input_id)},
        revision: revision.revision,
        inserted_at: revision.inserted_at,
        event_kind: revision.event_kind,
        actor_kind: revision.actor_kind,
        text: fragment("(?::jsonb)->>'text'", revision.content)
      }
    )
  end

  @doc "How many live messages received between `from` and `to` routing decided with each of `actions`."
  def decision_counts_between(from, to, actions) do
    all()
    |> where(
      [ingress_inbox_entries: e],
      e.execution_mode == :live and e.decision_action in ^actions and e.inserted_at >= ^from and
        e.inserted_at < ^to
    )
    |> group_by([ingress_inbox_entries: e], e.decision_action)
    |> select([ingress_inbox_entries: e], {e.decision_action, count()})
  end

  @doc "The messages admitted to `episode_id` up to `until`, the earliest first."
  def admitted_to(episode_id, until) do
    all()
    |> where(
      [ingress_inbox_entries: e],
      e.episode_id == ^episode_id and e.inserted_at <= ^until
    )
    |> order_by([ingress_inbox_entries: e], asc: e.inserted_at, asc: e.id)
  end

  def in_thread(queryable, thread_ref),
    do: where(queryable, [ingress_inbox_entries: e], e.destination_thread_ref == ^thread_ref)

  def select_ids(queryable), do: select(queryable, [ingress_inbox_entries: e], e.id)

  def select_destinations(queryable) do
    select(
      queryable,
      [ingress_inbox_entries: e],
      struct(e, [:id, :destination_transport, :destination_conversation_ref])
    )
  end

  # Keeps the message from being deleted until the transaction ends, without
  # blocking anything that only updates it.
  def lock_for_key_share(queryable), do: lock(queryable, "FOR KEY SHARE")

  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
