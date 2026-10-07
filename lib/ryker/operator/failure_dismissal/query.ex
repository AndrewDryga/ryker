defmodule Ryker.Operator.FailureDismissal.Query do
  @moduledoc "Failures people left as they are, for every read of `failure_dismissals`."
  import Ecto.Query
  alias Ryker.Operator.FailureDismissal

  def all, do: from(dismissals in FailureDismissal, as: :failure_dismissals)

  @doc "Dismissals of any of `kinds` and any of `refs`."
  def by_kinds_and_refs(kinds, refs),
    do: where(all(), [failure_dismissals: d], d.kind in ^kinds and d.ref in ^refs)

  def count_by_kind(queryable \\ all()) do
    queryable
    |> group_by([failure_dismissals: d], d.kind)
    |> select([failure_dismissals: d], {d.kind, count(d.ref)})
  end
end
