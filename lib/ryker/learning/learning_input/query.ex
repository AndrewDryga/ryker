defmodule Ryker.Learning.LearningInput.Query do
  @moduledoc """
  Routed messages as learning takes them: the ones no batch holds yet, when
  each became ready, and the conversations whose messages fall due as a
  batch. Each query starts from `Ryker.Ingress.Inbox.Entry.Query.all/0`.
  """
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.{Batch, ConversationObservation, InputMembership}
  alias Ryker.Work.OwningTurn

  @doc """
  Routed messages no batch holds yet, except one whose Work is still running:
  learned then, a request is learned from before Ryker has answered it.
  """
  def pending do
    from(e in Entry.Query.all(),
      where: e.status in [:decided, :superseded],
      where:
        not exists(
          from(m in InputMembership,
            where: m.input_id == parent_as(:ingress_inbox_entries).id
          )
        ),
      where:
        not exists(
          from(work in subquery(OwningTurn.Query.work_rest()),
            where:
              work.episode_id == parent_as(:ingress_inbox_entries).episode_id and work.running
          )
        )
    )
  end

  @doc """
  Of `queryable`'s messages, the ones learning can still use at `now`:
  decided, not a deletion, not pruned, with their content and their own
  observation, unexpired by `retention_seconds` (nil keeps it) and never one
  a person forgot.
  """
  def processable(queryable, now, retention_seconds) do
    cutoff = DateTime.add(now, -(retention_seconds || 0))

    from(e in queryable,
      where:
        e.status == :decided and e.event_kind != :delete and
          is_nil(e.operational_pruned_at) and not is_nil(e.content),
      where: exists(current_observation(retention_seconds, cutoff))
    )
  end

  defp current_observation(seconds, cutoff) do
    from(o in ConversationObservation,
      where:
        o.source_input_id == parent_as(:ingress_inbox_entries).id and
          o.revision == parent_as(:ingress_inbox_entries).revision and
          o.source_fingerprint == parent_as(:ingress_inbox_entries).event_fingerprint,
      where: is_nil(o.forgotten_at),
      where: ^is_nil(seconds) or o.updated_at > ^cutoff
    )
  end

  @doc "Of `pending`'s messages, the ones `processable` leaves out."
  def unavailable(pending, processable) do
    processable_ids = Entry.Query.select_ids(processable)
    from(e in pending, where: e.id not in subquery(processable_ids))
  end

  @doc "`pending`'s messages of conversation `scope`."
  def in_scope(pending, scope) do
    from(e in pending,
      where:
        e.destination_transport == ^scope.transport and
          e.destination_conversation_ref == ^scope.conversation_ref and
          fragment("? IS NOT DISTINCT FROM ?", e.repository_ref, ^scope.repository_ref) and
          e.execution_mode == ^scope.execution_mode
    )
  end

  @doc "The messages batch `batch_id` still learns from, oldest first."
  def held_by(batch_id) do
    from(e in Entry.Query.all(),
      join: m in InputMembership,
      on: m.input_id == e.id,
      where: m.batch_id == ^batch_id and is_nil(m.terminal_reason),
      order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  @doc """
  The first conversation of `pending` that falls due as a batch at `now` with
  no batch of its own in the way: its messages have been quiet for
  `quiet_seconds`, one has waited `maximum_delay_seconds`, or they fill a
  batch of `batch_size`. The exclusion is in SQL before the bounded scope
  selection; one paused conversation cannot hide healthy scopes behind a
  recent-candidate cap.
  """
  def next_due_scope(pending, settings, now) do
    from(scope in subquery(coalesced_scopes(pending, settings, now)),
      as: :learning_scope,
      where: not exists(subquery(Batch.Query.blocking_scope(now))),
      limit: 1
    )
  end

  defp coalesced_scopes(pending, settings, now) do
    from(input in subquery(ready(pending)),
      group_by: [
        input.transport,
        input.conversation_ref,
        input.repository_ref,
        input.execution_mode
      ],
      having:
        max(input.ready_at) <= ^DateTime.add(now, -settings.quiet_seconds) or
          min(input.ready_at) <= ^DateTime.add(now, -settings.maximum_delay_seconds) or
          count(input.id) >= ^settings.batch_size,
      order_by: [asc: min(input.inserted_at), asc: input.conversation_ref],
      select: %{
        transport: input.transport,
        conversation_ref: input.conversation_ref,
        repository_ref: input.repository_ref,
        execution_mode: input.execution_mode
      }
    )
  end

  @doc "The earliest moment after `since` at which a conversation's unlearned messages fall due."
  def next_scope_due_after(since, settings) do
    from(scope in subquery(scope_due_times(since, settings)),
      where: scope.due_at > ^since,
      select: min(scope.due_at)
    )
  end

  # When each conversation's unlearned messages become a batch by the clock:
  # the `coalesced_scopes/3` condition, solved for the time. Only messages
  # ready within the longest wait can make a conversation fall due after
  # `since`; one that also holds messages ready earlier fell due already, so
  # leaving those out can add a wake but never delays one, and the read stays
  # small however long the history.
  defp scope_due_times(since, settings) do
    recent = DateTime.add(since, -settings.maximum_delay_seconds, :second)

    from(input in subquery(ready(pending())),
      where: input.ready_at > ^recent,
      group_by: [
        input.transport,
        input.conversation_ref,
        input.repository_ref,
        input.execution_mode
      ],
      select: %{
        due_at:
          fragment(
            "LEAST(?, ?)",
            datetime_add(max(input.ready_at), ^settings.quiet_seconds, "second"),
            datetime_add(min(input.ready_at), ^settings.maximum_delay_seconds, "second")
          )
      }
    )
  end

  # Each message learning may take, with when it became ready: when routing
  # decided it or, for one whose Work came to rest after that, when it did.
  # Counted from the question, the quiet time ran out while Work was still
  # answering it.
  defp ready(pending) do
    from(e in pending,
      left_join: work in subquery(OwningTurn.Query.work_rest()),
      on: work.episode_id == e.episode_id,
      select: %{
        id: e.id,
        transport: e.destination_transport,
        conversation_ref: e.destination_conversation_ref,
        repository_ref: e.repository_ref,
        execution_mode: e.execution_mode,
        inserted_at: e.inserted_at,
        ready_at: fragment("GREATEST(?, ?)", e.updated_at, work.rested_at)
      }
    )
  end
end
