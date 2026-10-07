defmodule Ryker.CoopFleet.Worker.Query do
  @moduledoc "Enrolled Coop workers, for every read of `coop_workers`."
  use Ryker, :query
  alias Ryker.CoopFleet.{Placement, Worker}

  def all, do: from(workers in Worker, as: :coop_workers)

  def by_id(queryable \\ all(), id), do: where(queryable, [coop_workers: w], w.id == ^id)

  @doc """
  The worker a new placement goes to: eligible for `requirements`' workspace,
  not draining or revoked, seen since `cutoff` and not among `excluded_ids`,
  with the fewest current placements and the most free turn and session slots.
  """
  def placement_candidate(requirements, cutoff, excluded_ids) do
    current_states = Enum.map(Placement.current_states(), &Atom.to_string/1)

    from(w in all(),
      where:
        w.workspace_ref == ^requirements.workspace_ref and w.state == :eligible and
          is_nil(w.drain_requested_at) and is_nil(w.revoked_at) and
          w.last_seen_at >= ^cutoff and w.id not in ^excluded_ids,
      order_by: [
        asc:
          fragment(
            "(SELECT count(*) FROM coop_session_placements AS placement WHERE placement.worker_id = ? AND placement.state = ANY(?))",
            w.id,
            type(^current_states, {:array, :string})
          ),
        desc: fragment("COALESCE((?::jsonb ->> 'turn_slots_free')::integer, 0)", w.capacity),
        desc: fragment("COALESCE((?::jsonb ->> 'session_slots_free')::integer, 0)", w.capacity),
        asc: w.id
      ],
      limit: 1
    )
  end

  def seen_since(queryable \\ all(), cutoff),
    do: where(queryable, [coop_workers: w], w.last_seen_at >= ^cutoff)

  def select_ids(queryable), do: select(queryable, [coop_workers: w], w.id)
  def ordered_by_id(queryable), do: order_by(queryable, [coop_workers: w], asc: w.id)

  @doc """
  Each install the enrolled workers report, by workspace: how many workers
  and how many of them take work, as `%{ref, workers, eligible}`.
  """
  def installs do
    from(w in all(),
      where: w.state != :revoked and is_nil(w.revoked_at),
      group_by: w.workspace_ref,
      order_by: w.workspace_ref,
      select: %{
        ref: w.workspace_ref,
        workers: count(w.id),
        eligible: filter(count(w.id), w.state == :eligible)
      }
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")
end
