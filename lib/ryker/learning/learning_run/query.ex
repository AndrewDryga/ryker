defmodule Ryker.Learning.LearningRun.Query do
  @moduledoc "Each learning pass over a batch of messages, for every read of `conversation_learning_runs`."
  use Ryker, :query
  alias Ryker.Learning.{Batch, LearningRun}

  def all, do: from(runs in LearningRun, as: :conversation_learning_runs)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [conversation_learning_runs: r], r.id == ^id)

  def by_batch_key(queryable \\ all(), key),
    do: where(queryable, [conversation_learning_runs: r], r.batch_key == ^key)

  def by_batch_id(queryable \\ all(), batch_id),
    do: where(queryable, [conversation_learning_runs: r], r.batch_id == ^batch_id)

  def by_status(queryable, status),
    do: where(queryable, [conversation_learning_runs: r], r.status == ^status)

  def excluding_id(queryable, id),
    do: where(queryable, [conversation_learning_runs: r], r.id != ^id)

  def by_error_code(queryable, error_code),
    do: where(queryable, [conversation_learning_runs: r], r.error_code == ^error_code)

  def by_policy(queryable \\ all(), policy, policy_digest) do
    where(
      queryable,
      [conversation_learning_runs: r],
      r.policy == ^policy and r.policy_digest == ^policy_digest
    )
  end

  @doc "Passes of the batches of conversation scope `scope_key`."
  def by_scope(queryable \\ all(), scope_key) do
    queryable
    |> join(:inner, [conversation_learning_runs: r], b in Batch,
      on: b.id == r.batch_id,
      as: :conversation_learning_batches
    )
    |> where([conversation_learning_batches: b], b.scope_key == ^scope_key)
  end

  @doc "Passes started on a worker that has not confirmed their remote execution stopped."
  def unstopped(queryable) do
    where(
      queryable,
      [conversation_learning_runs: r],
      not is_nil(r.started_at) and is_nil(r.remote_stopped_at)
    )
  end

  @doc "Prepared passes that never started."
  def unstarted(queryable) do
    where(
      queryable,
      [conversation_learning_runs: r],
      r.status == :prepared and is_nil(r.started_at)
    )
  end

  @doc """
  The latest pass of batch `batch_id` under the batch's current policy and,
  for a rebuild, its current budget.
  """
  def latest_current(batch_id) do
    from(r in all(),
      join: b in Batch,
      on: b.id == r.batch_id,
      where:
        r.batch_id == ^batch_id and
          r.policy == b.policy and r.policy_digest == b.policy_digest and
          (is_nil(b.rebuild_target_id) or r.batch_budget_version == b.budget_version),
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: 1
    )
  end

  @doc "Passes that spent an attempt: started, or answered and decided."
  def attempted(queryable) do
    where(
      queryable,
      [conversation_learning_runs: r],
      not is_nil(r.started_at) or r.status in [:responded, :applied, :rejected]
    )
  end

  @doc "Passes that count against the retry budget: refused, or started."
  def failed_or_started(queryable) do
    where(
      queryable,
      [conversation_learning_runs: r],
      r.status == :rejected or not is_nil(r.started_at)
    )
  end

  def ordered_by_generation_desc(queryable),
    do: order_by(queryable, [conversation_learning_runs: r], desc: r.generation)

  def ordered_by_recent(queryable),
    do: order_by(queryable, [conversation_learning_runs: r], desc: r.inserted_at, desc: r.id)

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [conversation_learning_runs: r], asc: r.inserted_at, asc: r.id)

  def select_error_codes(queryable),
    do: select(queryable, [conversation_learning_runs: r], %{error_code: r.error_code})

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [conversation_learning_runs: r], r.id in ^ids)

  @doc "What links a knowledge update to the attempt that wrote it."
  def select_result_digests(queryable) do
    select(queryable, [conversation_learning_runs: r], %{
      id: r.id,
      status: r.status,
      inputs: r.inputs,
      remote_stopped_at: r.remote_stopped_at,
      result_sha256: r.result_sha256
    })
  end

  def by_batch_ids(queryable \\ all(), batch_ids),
    do: where(queryable, [conversation_learning_runs: r], r.batch_id in ^batch_ids)

  def unpruned(queryable),
    do: where(queryable, [conversation_learning_runs: r], is_nil(r.pruned_at))

  @doc "The batches the runs belong to, each once."
  def select_batch_ids(queryable),
    do: queryable |> distinct(true) |> select([conversation_learning_runs: r], r.batch_id)

  @doc "What each run returned: `%{id, result, inputs}`."
  def select_results(queryable) do
    select(queryable, [conversation_learning_runs: r], %{
      id: r.id,
      result: r.result,
      inputs: r.inputs
    })
  end

  @doc "What a batch's page shows of each attempt."
  def select_attempts(queryable) do
    select(queryable, [conversation_learning_runs: r], %{
      id: r.id,
      status: r.status,
      at: r.inserted_at,
      error_code: r.error_code,
      pruned_at: r.pruned_at,
      result: r.result,
      stop_receipt: r.stop_receipt,
      inputs: r.inputs,
      remote_stopped_at: r.remote_stopped_at
    })
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
end
