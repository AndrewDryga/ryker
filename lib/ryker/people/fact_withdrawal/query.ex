defmodule Ryker.People.FactWithdrawal.Query do
  @moduledoc "Personal fact withdrawal boundaries, independently of current profile labels."
  use Ryker, :query
  alias Ryker.People.FactWithdrawal

  def all, do: from(withdrawals in FactWithdrawal, as: :person_fact_withdrawals)

  def by_person(queryable \\ all(), person),
    do: where(queryable, [person_fact_withdrawals: w], w.person_ref == ^person)

  def blocking_source(queryable \\ all(), message, occurred_at) do
    where(
      queryable,
      [person_fact_withdrawals: w],
      w.source_message_ref == ^message or
        (is_nil(w.source_message_ref) and w.withdrawn_at >= ^occurred_at)
    )
  end

  @doc "A repeated withdrawal can advance its boundary, never move it backwards."
  def advance(queryable \\ all()) do
    update(queryable, [person_fact_withdrawals: w],
      set: [
        withdrawn_at: fragment("GREATEST(?, EXCLUDED.withdrawn_at)", w.withdrawn_at),
        updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", w.updated_at)
      ]
    )
  end
end
