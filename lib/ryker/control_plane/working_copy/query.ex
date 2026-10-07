defmodule Ryker.ControlPlane.WorkingCopy.Query do
  @moduledoc """
  What the Working copies and Learning pages read of worker sessions
  (`Ryker.ControlPlane.WorkspaceProjection`): every session with what its
  row names, the request it works for, or the learning run and batch.
  Admission sessions are routing's, and no page lists them.
  """
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Learning.{Batch, LearningRun}
  alias Ryker.Work.Session

  @doc """
  Every session as `{session, episode_state, episode_key, learning_run,
  learning_batch}`. A learning session has no episode; an inner join left
  every learning session, and any blocked cleanup of one, off both pages.
  """
  def sessions do
    from(session in Session,
      as: :session,
      left_join: episode in Episode,
      on: episode.id == session.episode_id,
      left_join: learning_run in LearningRun,
      on: learning_run.id == session.learning_run_id,
      left_join: learning_batch in Batch,
      on: learning_batch.id == learning_run.batch_id,
      select: {session, episode.state, episode.key, learning_run, learning_batch}
    )
  end

  @doc "Sessions that check out a repository for Work."
  def working_copies(queryable),
    do: where(queryable, [session: s], s.execution_kind == :work and not is_nil(s.repository_ref))

  def learning(queryable), do: where(queryable, [session: s], s.execution_kind == :learning)
  def removed(queryable), do: where(queryable, [session: s], s.cleanup_status == :discarded)
  def kept(queryable), do: where(queryable, [session: s], s.cleanup_status != :discarded)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [session: s], desc: s.updated_at, desc: s.id)

  @doc "The Work or learning session `external_ref`."
  def listed(queryable, external_ref) do
    where(
      queryable,
      [session: s],
      s.external_ref == ^external_ref and s.execution_kind in [:work, :learning]
    )
  end
end
