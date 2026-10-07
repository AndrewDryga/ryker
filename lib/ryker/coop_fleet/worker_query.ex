defmodule Ryker.CoopFleet.WorkerQuery do
  @moduledoc "Enrolled Coop workers, for every read of `coop_workers`."
  import Ecto.Query
  alias Ryker.CoopFleet.Worker

  def all, do: from(workers in Worker, as: :coop_workers)

  def by_id(queryable \\ all(), id), do: where(queryable, [coop_workers: w], w.id == ^id)
end
