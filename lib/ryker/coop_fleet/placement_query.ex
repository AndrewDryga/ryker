defmodule Ryker.CoopFleet.PlacementQuery do
  @moduledoc "Where each Coop session runs, for every read of `coop_session_placements`."
  import Ecto.Query
  alias Ryker.CoopFleet.{Placement, Worker}

  def all, do: from(placements in Placement, as: :coop_session_placements)

  def by_session_id(queryable \\ all(), session_id),
    do: where(queryable, [coop_session_placements: p], p.session_id == ^session_id)

  def latest_generation_first(queryable) do
    order_by(queryable, [coop_session_placements: p],
      desc: p.generation,
      desc: p.inserted_at
    )
  end

  @doc "Current placements whose lease ran out by `now`."
  def lease_expired_at(queryable, now),
    do: where(queryable, [coop_session_placements: p], p.lease_expires_at <= ^now)

  def current(queryable \\ all()),
    do: where(queryable, [coop_session_placements: p], p.state in ^Placement.current_states())

  @doc "Each placement with the worker it is on, as `:coop_workers`."
  def with_worker(queryable) do
    join(queryable, :inner, [coop_session_placements: p], w in Worker,
      on: w.id == p.worker_id,
      as: :coop_workers
    )
  end

  def select_workers(queryable), do: select(queryable, [coop_workers: w], w)

  @doc "Each placement's worker as `{id, state, revoked_at}`."
  def select_worker_standing(queryable),
    do: select(queryable, [coop_workers: w], {w.id, w.state, w.revoked_at})

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
