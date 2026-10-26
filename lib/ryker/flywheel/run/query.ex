defmodule Ryker.Flywheel.Run.Query do
  @moduledoc "Reads of the flywheel run ledger."
  use Ryker, :query
  alias Ryker.Flywheel.Run

  def all, do: from(runs in Run, as: :flywheel_runs)
  def by_id(queryable \\ all(), id), do: where(queryable, [flywheel_runs: r], r.id == ^id)

  def by_request_ref(queryable \\ all(), ref),
    do: where(queryable, [flywheel_runs: r], r.request_ref == ^ref)

  def running(queryable \\ all()), do: where(queryable, [flywheel_runs: r], r.status == :running)

  def ordered_by_oldest(queryable \\ all()),
    do: order_by(queryable, [flywheel_runs: r], asc: r.inserted_at, asc: r.id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
