defmodule Ryker.Flywheel.Finding.Query do
  @moduledoc "Findings across every pass, including decisions and unfinished outcome checks."
  use Ryker, :query
  alias Ryker.Flywheel.Finding

  def all, do: from(findings in Finding, as: :flywheel_findings)
  def by_id(queryable \\ all(), id), do: where(queryable, [flywheel_findings: f], f.id == ^id)
  def by_key(queryable \\ all(), key), do: where(queryable, [flywheel_findings: f], f.key == ^key)

  def ordered_by_oldest(queryable \\ all()),
    do: order_by(queryable, [flywheel_findings: f], asc: f.inserted_at, asc: f.id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
