defmodule Ryker.CoopFleet.CommandQuery do
  @moduledoc "Commands Ryker queued for its workers, for every read of `coop_worker_commands`."
  import Ecto.Query
  alias Ryker.CoopFleet.{Command, Placement}

  def all, do: from(commands in Command, as: :coop_worker_commands)

  def by_id(queryable \\ all(), id), do: where(queryable, [coop_worker_commands: c], c.id == ^id)

  def by_idempotency_key(queryable \\ all(), key),
    do: where(queryable, [coop_worker_commands: c], c.idempotency_key == ^key)

  def by_session_id(queryable \\ all(), session_id),
    do: where(queryable, [coop_worker_commands: c], c.session_id == ^session_id)

  def by_placement_id(queryable \\ all(), placement_id),
    do: where(queryable, [coop_worker_commands: c], c.placement_id == ^placement_id)

  def by_worker_id(queryable, worker_id),
    do: where(queryable, [coop_worker_commands: c], c.worker_id == ^worker_id)

  def of_kind(queryable, kind), do: where(queryable, [coop_worker_commands: c], c.kind == ^kind)

  @doc "Session `session_id`'s session creates that did not fail."
  def live_creates(session_id) do
    session_id
    |> by_session_id()
    |> of_kind("create_session")
    |> where([coop_worker_commands: c], c.status != :failed)
  end

  @doc """
  Command `command_id` while worker `worker_id` may upload its body at `now`:
  delivered under protocol 2 on the worker's active, leased placement of the
  same generation.
  """
  def uploadable(worker_id, command_id, now) do
    from(c in all(),
      join: p in Placement,
      on: p.id == c.placement_id,
      where:
        c.id == ^command_id and c.worker_id == ^worker_id and c.command_version == 2 and
          c.status in [:delivered, :acknowledged] and p.worker_id == ^worker_id and
          p.state == :active and p.generation == c.placement_generation and
          p.lease_expires_at > ^now,
      select: c
    )
  end

  def queued(queryable \\ all()),
    do: where(queryable, [coop_worker_commands: c], c.status == :queued)

  @doc "Commands that succeeded with a 2xx answer from the worker."
  def succeeded_2xx(queryable) do
    where(
      queryable,
      [coop_worker_commands: c],
      c.status == :succeeded and
        fragment("(?::jsonb -> 'status') BETWEEN '200'::jsonb AND '299'::jsonb", c.result)
    )
  end

  @doc """
  Commands worker `worker_id` would still be given: open, on a placement
  still active and leased at `now`, and, for a prepare, delivered no earlier
  than `prepare_cutoff` (Coop cancels one past its redelivery).
  """
  def waiting_on(worker_id, now, prepare_cutoff) do
    from(c in all(),
      join: p in Placement,
      as: :coop_session_placements,
      on: p.id == c.placement_id,
      where:
        c.worker_id == ^worker_id and c.status in [:queued, :delivered, :acknowledged] and
          p.state == :active and p.lease_expires_at > ^now,
      where:
        c.kind != "prepare_session" or is_nil(c.delivered_at) or c.delivered_at > ^prepare_cutoff
    )
  end

  @doc "Session `session_id`'s workspace setups that restored a checkpoint."
  def checkpoint_restores(session_id) do
    session_id
    |> by_session_id()
    |> of_kind("ensure_workspace")
    |> where(
      [coop_worker_commands: c],
      fragment("(?::jsonb -> 'checkpoint') IS NOT NULL", c.payload)
    )
  end

  @doc """
  The latest succeeded reconciliation of operation `operation_key` that
  `command`'s placement generation answered with a terminal state.
  """
  def terminal_reconciliation(command, operation_key) do
    from(c in all(),
      where:
        c.session_id == ^command.session_id and
          c.placement_generation == ^command.placement_generation and
          c.kind == "reconcile_operation" and c.status == :succeeded and
          fragment("(?::jsonb -> 'status') BETWEEN '200'::jsonb AND '299'::jsonb", c.result) and
          fragment("(?::jsonb ->> 'operation_key') = ?", c.payload, ^operation_key) and
          fragment("(?::jsonb -> 'body' ->> 'state') IN ('succeeded', 'failed')", c.result),
      order_by: [desc: c.completed_at, desc: c.id],
      limit: 1
    )
  end

  @doc """
  The ten latest workspace setups of session `session_id` that succeeded for
  Coop session `coop_session_id`.
  """
  def ensured_workspaces(session_id, coop_session_id) do
    from(c in all(),
      where:
        c.session_id == ^session_id and c.kind == "ensure_workspace" and
          c.status == :succeeded and
          fragment("(?::jsonb -> 'status') BETWEEN '200'::jsonb AND '299'::jsonb", c.result) and
          fragment("(?::jsonb ->> 'coop_session_id') = ?", c.payload, ^coop_session_id),
      order_by: [desc: c.completed_at, desc: c.id],
      limit: 10
    )
  end

  def of_placement_generation(queryable, generation),
    do: where(queryable, [coop_worker_commands: c], c.placement_generation == ^generation)

  def latest_completed_first(queryable),
    do: order_by(queryable, [coop_worker_commands: c], desc: c.completed_at, desc: c.id)

  def oldest_first(queryable),
    do: order_by(queryable, [coop_worker_commands: c], asc: c.inserted_at, asc: c.id)

  @doc "Each command with its placement (`waiting_on/3`), as `{command, placement}`."
  def select_with_placements(queryable),
    do: select(queryable, [coop_worker_commands: c, coop_session_placements: p], {c, p})

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")

  def select_oldest_insert(queryable),
    do: select(queryable, [coop_worker_commands: c], min(c.inserted_at))
end
