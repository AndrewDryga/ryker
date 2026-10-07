defmodule Ryker.Learning.Batch.Query do
  @moduledoc "Batches of messages learned from together, for every read of `conversation_learning_batches`."
  import Ecto.Query
  alias Ryker.Learning.{Batch, LearningRun}

  def all, do: from(batches in Batch, as: :conversation_learning_batches)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [conversation_learning_batches: b], b.id == ^id)

  def by_scope_key(queryable \\ all(), scope_key),
    do: where(queryable, [conversation_learning_batches: b], b.scope_key == ^scope_key)

  def by_statuses(queryable \\ all(), statuses),
    do: where(queryable, [conversation_learning_batches: b], b.status in ^statuses)

  @doc "How many batches each status holds, as `{status, count}`."
  def counts_by_status(queryable \\ all()) do
    queryable
    |> group_by([conversation_learning_batches: b], b.status)
    |> select([conversation_learning_batches: b], {b.status, count(b.id)})
  end

  def excluding_id(queryable, id),
    do: where(queryable, [conversation_learning_batches: b], b.id != ^id)

  def in_conversation(queryable \\ all(), transport, conversation_ref) do
    where(
      queryable,
      [conversation_learning_batches: b],
      b.transport == ^transport and b.conversation_ref == ^conversation_ref
    )
  end

  def by_execution_mode(queryable, execution_mode),
    do: where(queryable, [conversation_learning_batches: b], b.execution_mode == ^execution_mode)

  @doc "The batch that rebuilds generation `generation` of topic `knowledge_id`."
  def rebuilding(knowledge_id, generation) do
    where(
      all(),
      [conversation_learning_batches: b],
      b.rebuild_target_id == ^knowledge_id and b.rebuild_target_generation == ^generation
    )
  end

  @doc "Batches with a started pass that has not stopped."
  def with_joined_unstopped_run(queryable) do
    queryable
    |> join(:inner, [conversation_learning_batches: b], r in LearningRun,
      on: r.batch_id == b.id,
      as: :conversation_learning_runs
    )
    |> LearningRun.Query.unstopped()
  end

  @doc "Batches waiting for a worker or held by one."
  def active(queryable),
    do: where(queryable, [conversation_learning_batches: b], b.status in [:queued, :running])

  @doc """
  The earliest retry or hold that ends after `since`, and the earliest lease
  nobody renewed that runs out after it, as `[retry_at, lease_expires_at]`.
  """
  def next_due_after(since) do
    from(b in all(),
      where: b.status in [:queued, :running, :deferred],
      select: [
        filter(
          min(b.next_attempt_at),
          b.status in [:queued, :deferred] and b.next_attempt_at > ^since
        ),
        filter(min(b.lease_expires_at), b.status == :running and b.lease_expires_at > ^since)
      ]
    )
  end

  @doc """
  The oldest batch a worker may take at `now`, skipping any another worker
  holds: queued and due, running on a lease that ran out, or held with a
  started pass that has to be reconciled.
  """
  def next_claimable(now) do
    from(b in all(),
      where:
        (b.status == :queued and (is_nil(b.next_attempt_at) or b.next_attempt_at <= ^now)) or
          (b.status == :running and b.lease_expires_at <= ^now) or
          (b.status == :deferred and b.next_attempt_at <= ^now and
             exists(subquery(unstopped_run()))),
      order_by: [asc: b.inserted_at, asc: b.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc """
  The batches that keep the conversation scope of the parent query's
  `:learning_scope` binding from a new batch at `now`: queued or running,
  held until later, or with a started pass that has not stopped.
  """
  def blocking_scope(now) do
    from(b in all(),
      where:
        b.transport == parent_as(:learning_scope).transport and
          b.conversation_ref == parent_as(:learning_scope).conversation_ref and
          fragment(
            "? IS NOT DISTINCT FROM ?",
            b.repository_ref,
            parent_as(:learning_scope).repository_ref
          ) and
          b.execution_mode == parent_as(:learning_scope).execution_mode,
      where:
        b.status in [:queued, :running] or
          (b.status == :deferred and b.next_attempt_at > ^now) or
          exists(subquery(unstopped_run()))
    )
  end

  # A started pass of the parent query's batch whose remote execution has not stopped.
  defp unstopped_run do
    LearningRun.Query.all()
    |> LearningRun.Query.unstopped()
    |> where(
      [conversation_learning_runs: r],
      r.batch_id == parent_as(:conversation_learning_batches).id
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
