defmodule Ryker.CoopFleet.Placement.Query do
  @moduledoc "Where each Coop session runs, for every read of `coop_session_placements`."
  import Ecto.Query
  alias Ryker.CoopFleet.{Command, Placement, Worker}
  alias Ryker.Work.Session

  def all, do: from(placements in Placement, as: :coop_session_placements)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [coop_session_placements: p], p.id == ^id)

  @doc "The placement `command` was queued on: its worker, session and generation."
  def of_command(command) do
    where(
      all(),
      [coop_session_placements: p],
      p.id == ^command.placement_id and p.worker_id == ^command.worker_id and
        p.session_id == ^command.session_id and p.generation == ^command.placement_generation
    )
  end

  @doc "Worker `worker_id`'s placement of session `session_id` at `generation`."
  def of_worker_session(worker_id, session_id, generation) do
    where(
      all(),
      [coop_session_placements: p],
      p.worker_id == ^worker_id and p.session_id == ^session_id and p.generation == ^generation
    )
  end

  def by_worker_id(queryable \\ all(), worker_id),
    do: where(queryable, [coop_session_placements: p], p.worker_id == ^worker_id)

  def active(queryable),
    do: where(queryable, [coop_session_placements: p], p.state == :active)

  @doc """
  Worker `worker_id`'s current placements made after `since` whose session is
  not bound to a Coop session yet: sessions being created.
  """
  def unbound_since(worker_id, since) do
    from(p in all(),
      join: s in Session,
      on: s.id == p.session_id,
      where:
        p.worker_id == ^worker_id and p.state in ^Placement.current_states() and
          p.inserted_at > ^since and is_nil(s.coop_session_id)
    )
  end

  @doc "Placements through which the worker has not closed its session."
  def without_closed_session(queryable) do
    closed =
      from(c in Command,
        where:
          c.placement_id == parent_as(:coop_session_placements).id and
            c.kind == "close_session" and c.status == :succeeded and
            fragment("(?::jsonb -> 'status') BETWEEN '200'::jsonb AND '299'::jsonb", c.result) and
            fragment("?::jsonb #>> '{body,session,state}' = 'closed'", c.result) and
            fragment(
              "(?::jsonb #>> '{body,session,id}') = (?::jsonb ->> 'coop_session_id')",
              c.result,
              c.payload
            ),
        select: 1
      )

    where(queryable, not exists(subquery(closed)))
  end

  @doc """
  Worker `worker`'s placements a poll took out of `:active` that are still
  current though their lease ran out by `now`.
  """
  def expired_inactive(worker_id, now) do
    where(
      all(),
      [coop_session_placements: p],
      p.worker_id == ^worker_id and p.state in ^(Placement.current_states() -- [:active]) and
        p.lease_expires_at <= ^now
    )
  end

  @doc """
  Current placements no worker will renew: a revoked worker's and, with
  `judge_vanished?`, those whose lease ran out by `cutoff` on a worker last
  seen by then.
  """
  def abandoned(cutoff, judge_vanished?) do
    abandoned =
      if judge_vanished? do
        dynamic(
          [coop_session_placements: p, coop_workers: w],
          w.state == :revoked or (p.lease_expires_at <= ^cutoff and w.last_seen_at <= ^cutoff)
        )
      else
        dynamic([coop_workers: w], w.state == :revoked)
      end

    all()
    |> current()
    |> with_worker()
    |> where(^abandoned)
  end

  @doc "The workers holding `queryable`'s placements, each once, in id order."
  def select_worker_ids(queryable) do
    queryable
    |> distinct(true)
    |> order_by([coop_session_placements: p], asc: p.worker_id)
    |> select([coop_session_placements: p], p.worker_id)
  end

  def select_max_generation(queryable),
    do: select(queryable, [coop_session_placements: p], coalesce(max(p.generation), 0))

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def by_session_ids(queryable \\ all(), session_ids),
    do: where(queryable, [coop_session_placements: p], p.session_id in ^session_ids)

  @doc "Each session's placements together, its latest generation first."
  def latest_per_session_first(queryable) do
    order_by(queryable, [coop_session_placements: p],
      asc: p.session_id,
      desc: p.generation,
      desc: p.id
    )
  end

  def select_session_workers(queryable),
    do: select(queryable, [coop_session_placements: p], {p.session_id, p.worker_id})

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

  @doc "Each placement with its worker, as `{placement, worker}`."
  def select_with_workers(queryable),
    do: select(queryable, [coop_session_placements: p, coop_workers: w], {p, w})

  @doc "Each placement's worker as `{id, state, revoked_at}`."
  def select_worker_standing(queryable),
    do: select(queryable, [coop_workers: w], {w.id, w.state, w.revoked_at})

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
