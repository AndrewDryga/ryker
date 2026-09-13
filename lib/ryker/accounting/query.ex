defmodule Ryker.Accounting.Query do
  @moduledoc """
  The execution ledger as one priced query.

  Every execution has its `execution_usage` row before it reaches Coop: Work
  records `requested` before the turn is submitted, admission and learning
  record inside the transaction that owns their attempt. Nothing is read from
  the turn's own usage columns here; those are the turn's snapshot, not the ledger.
  """
  import Ecto.Query
  alias Ryker.Accounting.{Execution, Pricing}

  @fields Execution.__schema__(:fields) -- [:inserted_at, :updated_at]

  def executions(since, mode \\ "live") do
    query = from(e in Execution, select: map(e, ^@fields))
    query = if since, do: where(query, [e], e.recorded_at >= ^since), else: query
    query = if mode == "all", do: query, else: where(query, [e], e.execution_mode == ^mode)
    Pricing.enrich(query)
  end
end
