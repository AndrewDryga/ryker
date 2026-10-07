defmodule Ryker.Admission.AttemptQuery do
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
