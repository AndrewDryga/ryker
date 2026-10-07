defmodule Ryker.CoopFleet.WorkspaceCheckpointTransferQuery do
  @moduledoc "Workspace checkpoints workers saved to Ryker, for every read of `coop_worker_workspace_checkpoints`."
  import Ecto.Query
  alias Ryker.CoopFleet.{Command, WorkspaceCheckpointTransfer}

  def all,
    do: from(transfers in WorkspaceCheckpointTransfer, as: :coop_worker_workspace_checkpoints)

  def select_latest_insert(queryable),
    do: select(queryable, [coop_worker_workspace_checkpoints: t], max(t.inserted_at))

  @doc "The descriptor of the latest checkpoint the succeeded command keyed `idempotency_key` saved."
  def latest_descriptor(idempotency_key) do
    from(t in all(),
      join: c in Command,
      on: c.id == t.command_id,
      where: c.idempotency_key == ^idempotency_key and c.status == :succeeded,
      order_by: [desc: t.inserted_at, desc: t.id],
      limit: 1,
      select: t.descriptor
    )
  end

  @doc """
  The checkpoints saved for session `session_id` by the command keyed
  `idempotency_key`, when that command succeeded with a 2xx status.
  """
  def saved_by(session_id, idempotency_key) do
    from(t in all(),
      join: c in Command,
      on: c.id == t.command_id,
      where:
        c.session_id == ^session_id and c.idempotency_key == ^idempotency_key and
          c.status == :succeeded and
          fragment("(?::jsonb -> 'status') BETWEEN '200'::jsonb AND '299'::jsonb", c.result)
    )
  end
end
