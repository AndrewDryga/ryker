defmodule Ryker.CoopFleet.PlacementQuery do
  @moduledoc "Where each Coop session runs, for every read of `coop_session_placements`."
  import Ecto.Query
  alias Ryker.CoopFleet.Placement

  def all, do: from(placements in Placement, as: :coop_session_placements)

  def by_session_id(queryable \\ all(), session_id),
    do: where(queryable, [coop_session_placements: p], p.session_id == ^session_id)

  def latest_generation_first(queryable) do
    order_by(queryable, [coop_session_placements: p],
      desc: p.generation,
      desc: p.inserted_at
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
