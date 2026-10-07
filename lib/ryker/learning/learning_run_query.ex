defmodule Ryker.Learning.LearningRunQuery do
  @moduledoc "Each learning pass over a batch of messages, for every read of `conversation_learning_runs`."
  import Ecto.Query
  alias Ryker.Learning.LearningRun

  def all, do: from(runs in LearningRun, as: :conversation_learning_runs)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [conversation_learning_runs: r], r.id == ^id)

  def by_batch_key(queryable \\ all(), key),
    do: where(queryable, [conversation_learning_runs: r], r.batch_key == ^key)

  def by_batch_id(queryable \\ all(), batch_id),
    do: where(queryable, [conversation_learning_runs: r], r.batch_id == ^batch_id)

  def with_status(queryable, status),
    do: where(queryable, [conversation_learning_runs: r], r.status == ^status)

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

  def latest_generation_first(queryable),
    do: order_by(queryable, [conversation_learning_runs: r], desc: r.generation)

  def newest_first(queryable),
    do: order_by(queryable, [conversation_learning_runs: r], desc: r.inserted_at, desc: r.id)

  def select_error_codes(queryable),
    do: select(queryable, [conversation_learning_runs: r], %{error_code: r.error_code})

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
