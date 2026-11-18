defmodule Ryker.GitHub.CIRepairRound.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.GitHub.CIRepairRound

  def all, do: from(rounds in CIRepairRound, as: :github_ci_repair_rounds)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [github_ci_repair_rounds: r], r.id == ^id)

  def by_entry_id(queryable \\ all(), id),
    do: where(queryable, [github_ci_repair_rounds: r], r.entry_id == ^id)
end
