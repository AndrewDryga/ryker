defmodule Ryker.CoopFleet.Command.Query do
  @moduledoc "Commands Ryker queued for its workers, for every read of `coop_worker_commands`."
  use Ryker, :query
  alias Ryker.CoopFleet.{Command, Placement, Worker}
  alias Ryker.WeeklyReport
  alias Ryker.Work

  def all, do: from(commands in Command, as: :coop_worker_commands)

  def by_id(queryable \\ all(), id), do: where(queryable, [coop_worker_commands: c], c.id == ^id)

  def by_idempotency_key(queryable \\ all(), key),
    do: where(queryable, [coop_worker_commands: c], c.idempotency_key == ^key)

  def by_session_id(queryable \\ all(), session_id),
    do: where(queryable, [coop_worker_commands: c], c.session_id == ^session_id)

  def by_session_ids(queryable \\ all(), session_ids),
    do: where(queryable, [coop_worker_commands: c], c.session_id in ^session_ids)

  @doc "The latest transport or HTTP error for this session, selecting no request or response body."
  def last_failed_kind(session_id) do
    from(c in by_session_id(session_id),
      where:
        c.status == :failed or
          (c.status == :succeeded and
             fragment("(?::jsonb -> 'status') BETWEEN '400'::jsonb AND '599'::jsonb", c.result)),
      order_by: [desc: c.completed_at, desc: c.id],
      limit: 1,
      select: c.kind
    )
  end

  @doc "Copied weekly-review bodies whose owner was revoked and has durable remote stop proof."
  def stopped_revoked_weekly(queryable \\ all()) do
    from(c in queryable,
      join: s in Work.Session,
      on: s.id == c.session_id,
      join: r in WeeklyReport.Review,
      on: r.id == s.weekly_review_id,
      where:
        (not is_nil(r.forgotten_at) or not is_nil(r.pruned_at)) and
          not is_nil(r.remote_stopped_at) and c.kind in ["submit_turn", "get_turn"]
    )
  end

  def settled(queryable),
    do: where(queryable, [coop_worker_commands: c], c.status in [:succeeded, :failed, :uncertain])

  @doc "Commands whose execution has not been conclusively settled."
  def unsettled(queryable) do
    where(
      queryable,
      [coop_worker_commands: c],
      c.status in [:queued, :delivered, :acknowledged, :uncertain]
    )
  end

  def by_placement_id(queryable \\ all(), placement_id),
    do: where(queryable, [coop_worker_commands: c], c.placement_id == ^placement_id)

  def by_worker_id(queryable, worker_id),
    do: where(queryable, [coop_worker_commands: c], c.worker_id == ^worker_id)

  def by_kind(queryable, kind), do: where(queryable, [coop_worker_commands: c], c.kind == ^kind)

  @doc "The commands that succeeded under a key starting with `prefix`."
  def succeeded_with_key_prefix(queryable, prefix) when is_binary(prefix) do
    where(
      queryable,
      [coop_worker_commands: c],
      c.status == :succeeded and fragment("starts_with(?, ?)", c.idempotency_key, ^prefix)
    )
  end

  @doc "Session `session_id`'s session creates that did not fail."
  def live_creates(session_id) do
    session_id
    |> by_session_id()
    |> by_kind("create_session")
    |> where([coop_worker_commands: c], c.status != :failed)
  end

  @doc "Every create attempt of this exact local session, including uncertain failures."
  def creates(session_id) do
    session_id
    |> by_session_id()
    |> by_kind("create_session")
    |> ordered_by_oldest()
  end

  @doc "Every distinct create reconciliation result on the original holder, including cleanup-only recovery."
  def select_creation_reconciliation_results(command) do
    from(c in all(),
      join: p in Placement,
      on:
        p.id == c.placement_id and p.worker_id == c.worker_id and
          p.session_id == c.session_id and p.generation == c.placement_generation,
      where:
        c.session_id == ^command.session_id and c.worker_id == ^command.worker_id and
          c.kind == "reconcile_operation" and c.status == :succeeded and
          fragment("(?::jsonb ->> 'operation_key') = ?", c.payload, ^command.idempotency_key),
      where:
        c.placement_id == ^command.placement_id or
          fragment("(?::jsonb ->> 'purpose') = 'stop_or_cleanup'", p.requirements),
      distinct: true,
      select: c.result
    )
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
  still active and leased at `now`; for a prepare, delivered no earlier than
  `prepare_cutoff` (Coop cancels one past its redelivery); for a read, asked
  no earlier than `read_cutoff` (no caller waits for its answer longer).
  """
  def waiting_on(worker_id, now, prepare_cutoff, read_cutoff) do
    reads = Command.read_key_prefix() <> "%"

    from(c in all(),
      join: p in Placement,
      as: :coop_session_placements,
      on: p.id == c.placement_id,
      where: c.kind != "submit_turn" or c.session_id not in subquery(revoked_weekly_sessions()),
      where:
        c.worker_id == ^worker_id and c.status in [:queued, :delivered, :acknowledged] and
          p.state == :active and p.lease_expires_at > ^now,
      where:
        c.kind != "prepare_session" or is_nil(c.delivered_at) or c.delivered_at > ^prepare_cutoff,
      where: not like(c.idempotency_key, ^reads) or c.inserted_at > ^read_cutoff
    )
  end

  @doc "Hold new mutations while drained, but deliver reads, settlement and already leased commands."
  def allowed_while_draining(queryable) do
    settling =
      ~w(get_review get_review_gate_output get_checkpoint_bundle get_session get_session_evidence get_turn get_output_artifact get_changes get_changes_page reconcile_operation validate_candidate cancel_turn)

    from(c in queryable,
      join: w in Worker,
      on: w.id == c.worker_id,
      where:
        is_nil(w.drain_requested_at) or not is_nil(c.delivered_at) or c.kind in ^settling or
          (c.kind == "api_request" and
             (fragment("?::jsonb ->> 'method' IN ('GET', 'HEAD')", c.payload) or
                fragment(
                  "(?::jsonb ->> 'method' = 'POST') AND (?::jsonb ->> 'path') ~ '^/v1/sessions/[^/]+/turns/[^/]+/(validation|cancel)$'",
                  c.payload,
                  c.payload
                )))
    )
  end

  defp revoked_weekly_sessions do
    from(s in Work.Session,
      join: r in WeeklyReport.Review,
      on: r.id == s.weekly_review_id,
      where: not is_nil(r.forgotten_at) or not is_nil(r.pruned_at),
      select: s.id
    )
  end

  @doc """
  Commands still delivered or acknowledged whose placement was replaced or
  retired before `cutoff`. A worker sends a command's result again until Ryker
  takes it, so a result that has not come since will not come.
  """
  def orphaned(cutoff) do
    from(c in all(),
      join: p in Placement,
      as: :coop_session_placements,
      on: p.id == c.placement_id,
      where:
        c.status in [:delivered, :acknowledged] and p.state in [:replaced, :retired] and
          p.updated_at < ^cutoff
    )
  end

  def select_worker_ids(queryable),
    do: queryable |> select([coop_worker_commands: c], c.worker_id) |> distinct(true)

  @doc "Session `session_id`'s workspace setups that restored a checkpoint."
  def checkpoint_restores(session_id) do
    session_id
    |> by_session_id()
    |> by_kind("ensure_workspace")
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
          c.worker_id == ^command.worker_id and c.placement_id == ^command.placement_id and
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

  def by_placement_generation(queryable, generation),
    do: where(queryable, [coop_worker_commands: c], c.placement_generation == ^generation)

  def ordered_by_completed_at_desc(queryable),
    do: order_by(queryable, [coop_worker_commands: c], desc: c.completed_at, desc: c.id)

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [coop_worker_commands: c], asc: c.inserted_at, asc: c.id)

  @doc "Each command with its placement (`waiting_on/3`), as `{command, placement}`."
  def select_with_placements(queryable),
    do: select(queryable, [coop_worker_commands: c, coop_session_placements: p], {c, p})

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def lock_command_for_update(queryable),
    do: lock(queryable, [coop_worker_commands: c], fragment("FOR UPDATE OF ?", c))

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")

  def select_oldest_insert(queryable),
    do: select(queryable, [coop_worker_commands: c], min(c.inserted_at))
end
