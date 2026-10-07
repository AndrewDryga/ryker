defmodule Ryker.CoopFleet.WorkspaceCheckpointTransfer.Query do
  @moduledoc "Workspace checkpoints workers saved to Ryker, for every read of `coop_worker_workspace_checkpoints`."
  import Ecto.Query
  alias Ryker.CoopFleet.{Command, WorkspaceCheckpointTransfer}
  alias Ryker.Work.Session

  def all,
    do: from(transfers in WorkspaceCheckpointTransfer, as: :coop_worker_workspace_checkpoints)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [coop_worker_workspace_checkpoints: t], t.id == ^id)

  @doc "Checkpoint `checkpoint_ref` that command `command_id` saved."
  def by_command_checkpoint(command_id, checkpoint_ref) do
    where(
      all(),
      [coop_worker_workspace_checkpoints: t],
      t.command_id == ^command_id and t.checkpoint_ref == ^checkpoint_ref
    )
  end

  def select_latest_insert(queryable),
    do: select(queryable, [coop_worker_workspace_checkpoints: t], max(t.inserted_at))

  @doc """
  The latest checkpoint a replacement of `session` may restore, with the
  session it was taken from, as `{transfer, source}`: saved with a 2xx answer
  by an earlier generation of the same episode on the same repository.
  """
  def latest_for_replacement(session) do
    from(t in all(),
      join: c in Command,
      on: c.id == t.command_id,
      join: source in Session,
      on: source.id == c.session_id,
      where:
        source.episode_id == ^session.episode_id and source.generation < ^session.generation and
          source.repository_ref == ^session.repository_ref and c.status == :succeeded and
          fragment("(?::jsonb -> 'status') BETWEEN '200'::jsonb AND '299'::jsonb", c.result),
      order_by: [desc: t.inserted_at, desc: t.id],
      limit: 1,
      select: {t, source}
    )
  end

  @doc """
  The newest checkpoint a rotation of `session` would restore: same episode
  and repository, taken by this generation or one before it, as
  `{checkpoint, source_repository_source}`. Only its metadata is read.
  """
  def latest_portable(session) do
    from(t in all(),
      join: c in Command,
      on: c.id == t.command_id,
      join: source in Session,
      on: source.id == c.session_id,
      where:
        source.episode_id == ^session.episode_id and source.generation <= ^session.generation and
          source.repository_ref == ^session.repository_ref and c.status == :succeeded and
          fragment("(?::jsonb -> 'status') BETWEEN '200'::jsonb AND '299'::jsonb", c.result),
      order_by: [desc: t.inserted_at, desc: t.id],
      limit: 1,
      select: {
        %{
          byte_size: t.bundle_byte_size,
          checkpoint_ref: t.checkpoint_ref,
          repository_ref: t.repository_ref,
          sha256: t.bundle_sha256,
          body_command_id: t.body_command_id,
          descriptor: t.descriptor
        },
        source.repository_source
      }
    )
  end

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
