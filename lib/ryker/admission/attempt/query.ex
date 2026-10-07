defmodule Ryker.Admission.Attempt.Query do
  @moduledoc "Routing attempts, for every read of `admission_attempts`."
  import Ecto.Query
  alias Ryker.Admission.Attempt

  def all, do: from(attempts in Attempt, as: :admission_attempts)

  def for_generation(queryable \\ all(), input_id, generation) do
    where(
      queryable,
      [admission_attempts: a],
      a.input_id == ^input_id and a.generation == ^generation
    )
  end

  def prompted(queryable), do: where(queryable, [admission_attempts: a], not is_nil(a.submission))

  def by_input_id(queryable \\ all(), input_id),
    do: where(queryable, [admission_attempts: a], a.input_id == ^input_id)

  def by_input_ids(queryable \\ all(), input_ids),
    do: where(queryable, [admission_attempts: a], a.input_id in ^input_ids)

  def ordered_by_recent(queryable),
    do: order_by(queryable, [admission_attempts: a], desc: a.inserted_at, desc: a.id)

  def ordered_by_generation_desc(queryable),
    do: order_by(queryable, [admission_attempts: a], desc: a.generation)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc "The messages that kept a routing attempt, each once."
  def select_input_ids(queryable),
    do: queryable |> distinct(true) |> select([admission_attempts: a], a.input_id)

  @doc "The committed attempt of `entry`'s current routing, while it keeps its bodies."
  def committed_for(entry) do
    where(
      all(),
      [admission_attempts: a],
      a.input_id == ^entry.id and a.generation == ^entry.execution_generation and
        a.phase == "committed" and is_nil(a.operational_pruned_at)
    )
  end
end
