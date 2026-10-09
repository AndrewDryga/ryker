defmodule Ryker.Ingress.Inbox.Entry.Query do
  @moduledoc "Recorded messages and events, for every read of `ingress_inbox_entries`."
  use Ryker, :query
  alias Ryker.Ingress.Inbox.Entry

  def all, do: from(entries in Entry, as: :ingress_inbox_entries)

  def by_id(queryable \\ all(), id), do: where(queryable, [ingress_inbox_entries: e], e.id == ^id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [ingress_inbox_entries: e], e.id in ^ids)

  def by_conversation(queryable \\ all(), conversation_ref) do
    where(
      queryable,
      [ingress_inbox_entries: e],
      e.destination_conversation_ref == ^conversation_ref
    )
  end

  @doc """
  The messages of `entry`'s conversation before `before`, other than
  `excluded_ids`, the newest first: the thread a learning pass may read.
  """
  def earlier_in_conversation(entry, excluded_ids, before) do
    from(e in all(),
      where:
        e.destination_transport == ^entry.destination_transport and
          e.destination_conversation_ref == ^entry.destination_conversation_ref and
          e.id not in ^excluded_ids and e.occurred_at < ^before,
      order_by: [desc: e.occurred_at, desc: e.id]
    )
  end

  @doc "The messages that opened the threads `thread_refs` names."
  def thread_openings(queryable, thread_refs),
    do: where(queryable, [ingress_inbox_entries: e], e.source_item_ref in ^thread_refs)

  @doc "Replies in the threads `thread_refs` names, not their openings."
  def thread_replies(queryable, thread_refs) do
    where(
      queryable,
      [ingress_inbox_entries: e],
      e.destination_thread_ref in ^thread_refs and
        (is_nil(e.source_item_ref) or e.source_item_ref not in ^thread_refs)
    )
  end

  @doc """
  The messages each `{conversation, message}` names: by its platform item,
  or by its native id when it has none.
  """
  def by_messages(messages) do
    matching =
      Enum.reduce(messages, dynamic(false), fn {conversation, message}, matching ->
        dynamic(
          [ingress_inbox_entries: e],
          ^matching or
            (e.destination_conversation_ref == ^conversation and
               (e.source_item_ref == ^message or
                  (is_nil(e.source_item_ref) and e.native_input_id == ^message)))
        )
      end)

    where(all(), ^matching)
  end

  def ordered_by_occurred_at_desc(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], desc: e.occurred_at, desc: e.id)

  def having_admission_context(queryable),
    do: where(queryable, [ingress_inbox_entries: e], not is_nil(e.admission_context))

  def having_decision_document(queryable),
    do: where(queryable, [ingress_inbox_entries: e], not is_nil(e.decision_document))

  def select_admission_contexts(queryable),
    do: select(queryable, [ingress_inbox_entries: e], e.admission_context)

  @doc "Each routing decision as `{source_kind, source_ref, event_ref, decision_document}`."
  def select_decisions(queryable) do
    select(
      queryable,
      [ingress_inbox_entries: e],
      {e.source_kind, e.source_ref, e.event_ref, e.decision_document}
    )
  end

  def ordered_by_occurred_at(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], asc: e.occurred_at, asc: e.id)

  def ordered_by_id(queryable), do: order_by(queryable, [ingress_inbox_entries: e], asc: e.id)

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], asc: e.inserted_at, asc: e.id)

  def by_dedupe_key(queryable \\ all(), dedupe_key),
    do: where(queryable, [ingress_inbox_entries: e], e.dedupe_key == ^dedupe_key)

  def blocked(queryable \\ all()),
    do: where(queryable, [ingress_inbox_entries: e], e.status == :blocked)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], desc: e.updated_at, desc: e.id)

  defp pending(queryable \\ all()),
    do: where(queryable, [ingress_inbox_entries: e], e.status == :pending)

  @doc """
  The pending input that keeps `entry` out of the claimable set at `now`: an
  earlier pending input of its transport, conversation and execution mode,
  or one whose routing lease is still live.
  """
  def queue_predecessor(entry, now) do
    from(other in pending(),
      where: other.id != ^entry.id,
      where:
        other.destination_transport == ^entry.destination_transport and
          other.destination_conversation_ref == ^entry.destination_conversation_ref and
          other.execution_mode == ^entry.execution_mode,
      where:
        other.inserted_at < ^entry.inserted_at or
          (other.inserted_at == ^entry.inserted_at and other.id < ^entry.id) or
          (not is_nil(other.lease_ref) and other.lease_expires_at > ^now),
      order_by: [asc: other.inserted_at, asc: other.id],
      limit: 1
    )
  end

  @doc "Voice messages still waiting for their transcript."
  def awaiting_transcript(queryable \\ all()) do
    queryable
    |> pending()
    |> where([ingress_inbox_entries: e], not is_nil(e.awaiting_transcript_until))
  end

  @doc """
  The inputs routing may claim at `now`. Admission's candidates cover the
  whole destination conversation, so that boundary is serialized, not the
  whole inbox: a backoff must not let a later message overtake its missing
  context, nor a voice message's transcript.
  """
  def claimable_at(now) do
    from(e in pending(),
      where: is_nil(e.next_attempt_at) or e.next_attempt_at <= ^now,
      where: is_nil(e.lease_ref) or e.lease_expires_at <= ^now,
      where: is_nil(e.awaiting_transcript_until) or e.awaiting_transcript_until <= ^now,
      where: not exists(subquery(conversation_predecessor(now)))
    )
  end

  # An earlier pending input of the claimed one's lane, or one whose routing
  # lease is still live at `now`.
  defp conversation_predecessor(now) do
    from(other in Entry,
      where: other.status == :pending and other.id != parent_as(:ingress_inbox_entries).id,
      where:
        other.destination_transport == parent_as(:ingress_inbox_entries).destination_transport and
          other.destination_conversation_ref ==
            parent_as(:ingress_inbox_entries).destination_conversation_ref and
          other.execution_mode == parent_as(:ingress_inbox_entries).execution_mode,
      where:
        other.inserted_at < parent_as(:ingress_inbox_entries).inserted_at or
          (other.inserted_at == parent_as(:ingress_inbox_entries).inserted_at and
             other.id < parent_as(:ingress_inbox_entries).id) or
          (not is_nil(other.lease_ref) and other.lease_expires_at > ^now),
      select: 1
    )
  end

  @doc "The next retry, lease expiry and transcript wait end after `since` among pending inputs."
  def select_next_due_after(since) do
    select(pending(), [ingress_inbox_entries: e], [
      filter(min(e.next_attempt_at), e.next_attempt_at > ^since),
      filter(min(e.lease_expires_at), not is_nil(e.lease_ref) and e.lease_expires_at > ^since),
      filter(min(e.awaiting_transcript_until), e.awaiting_transcript_until > ^since)
    ])
  end

  @doc "The recorded revision of `input`'s source item: same revision and event."
  def same_revision(input) do
    from(e in all(),
      where:
        e.source_kind == ^input.source.kind and e.source_ref == ^input.source.ref and
          e.native_input_id == ^input.native_input_id and e.revision == ^input.revision and
          e.event_kind == ^input.event_kind,
      order_by: [asc: e.inserted_at],
      limit: 1
    )
  end

  @doc "The revisions recorded of `input`'s source item."
  def revisions_of(input) do
    where(
      all(),
      [ingress_inbox_entries: e],
      e.source_kind == ^input.source.kind and e.source_ref == ^input.source.ref and
        e.native_input_id == ^input.native_input_id
    )
  end

  def revision_between(queryable, low, high) do
    where(
      queryable,
      [ingress_inbox_entries: e],
      e.revision >= ^low and e.revision <= ^high
    )
  end

  def select_latest_revision(queryable),
    do: select(queryable, [ingress_inbox_entries: e], max(e.revision))

  def select_broadcast_fields(queryable) do
    select(
      queryable,
      [ingress_inbox_entries: e],
      struct(e, [:id, :episode_id, :destination_transport, :destination_conversation_ref])
    )
  end

  def by_source_event(queryable \\ all(), source_kind, event_ref) do
    where(
      queryable,
      [ingress_inbox_entries: e],
      e.source_kind == ^source_kind and e.event_ref == ^event_ref
    )
  end

  def ordered_by_recent(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], desc: e.inserted_at, desc: e.id)

  @doc "The latest said first: by occurrence, then revision, then arrival."
  def ordered_by_occurred_at_and_revision_desc(queryable) do
    order_by(queryable, [ingress_inbox_entries: e],
      desc: e.occurred_at,
      desc: e.revision,
      desc: e.inserted_at
    )
  end

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [ingress_inbox_entries: e], e.episode_id == ^episode_id)

  def by_episode_ids(queryable \\ all(), episode_ids),
    do: where(queryable, [ingress_inbox_entries: e], e.episode_id in ^episode_ids)

  @doc "The deletions of the source items `native_input_ids` names."
  def deletions_of_items(native_input_ids) do
    where(
      all(),
      [ingress_inbox_entries: e],
      e.event_kind == :delete and e.native_input_id in ^native_input_ids
    )
  end

  @doc "Each entry's source item, as `{source_kind, source_ref, native_input_id}`."
  def select_source_items(queryable) do
    select(
      queryable,
      [ingress_inbox_entries: e],
      {e.source_kind, e.source_ref, e.native_input_id}
    )
  end

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

  @doc "The newest later revision of `entry`'s message recorded in its execution mode, if any."
  def newest_later_revision(entry) do
    entry
    |> later_revisions_of()
    |> where([ingress_inbox_entries: e], e.execution_mode == ^entry.execution_mode)
    |> select_latest_revision()
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

  @doc """
  The deletions of any of `messages`, each `{conversation_ref, message_ref}`:
  a message is named by its source item, or by its native id without one.
  """
  def deletions_of(messages) do
    {conversation_refs, message_refs} = Enum.unzip(messages)

    where(
      all(),
      [ingress_inbox_entries: e],
      e.event_kind == :delete and
        fragment(
          "(?, COALESCE(?, ?)) IN (SELECT * FROM unnest(?::text[], ?::text[]))",
          e.destination_conversation_ref,
          e.source_item_ref,
          e.native_input_id,
          ^conversation_refs,
          ^message_refs
        )
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

  @doc "The other messages of `entry`'s thread, in its execution mode."
  def others_in_thread(entry) do
    where(
      all(),
      [ingress_inbox_entries: e],
      e.destination_transport == ^entry.destination_transport and
        e.destination_conversation_ref == ^entry.destination_conversation_ref and
        e.destination_thread_ref == ^entry.destination_thread_ref and
        e.execution_mode == ^entry.execution_mode and
        e.native_input_id != ^entry.native_input_id
    )
  end

  def by_thread_ref(queryable, thread_ref),
    do: where(queryable, [ingress_inbox_entries: e], e.destination_thread_ref == ^thread_ref)

  @doc "Messages waiting for routing whose routing lease is held at `now`."
  def leased_at(now) do
    where(
      all(),
      [ingress_inbox_entries: e],
      e.status == :pending and not is_nil(e.lease_ref) and e.lease_expires_at > ^now
    )
  end

  def select_ids(queryable), do: select(queryable, [ingress_inbox_entries: e], e.id)

  def select_pruned_at(queryable),
    do: select(queryable, [ingress_inbox_entries: e], e.operational_pruned_at)

  @doc "Each message as `{episode_id, destination_transport, destination_conversation_ref}`."
  def select_episode_destinations(queryable) do
    select(
      queryable,
      [ingress_inbox_entries: e],
      {e.episode_id, e.destination_transport, e.destination_conversation_ref}
    )
  end

  def select_earliest_insert(queryable),
    do: select(queryable, [ingress_inbox_entries: e], min(e.inserted_at))

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
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
