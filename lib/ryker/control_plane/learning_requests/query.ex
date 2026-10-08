defmodule Ryker.ControlPlane.LearningRequests.Query do
  @moduledoc """
  What a request's and a message's pages read of the learning that read
  their messages (`Ryker.ControlPlane.LearningRequests`): the batches and
  attempts that reached them, how each attempt is numbered in its batch,
  the topic revisions each wrote, and the request each message joined.
  """
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Knowledge
  alias Ryker.Learning

  @doc "Each of `input_ids` with the request it joined, as `{input_id, episode_id}`."
  def message_requests(input_ids) do
    from(entry in Ingress.Inbox.Entry,
      left_join: episode in Episodes.Episode,
      on: episode.id == entry.episode_id,
      where: entry.id in ^input_ids,
      select: {entry.id, episode.id}
    )
  end

  @doc "The batches that hold any of `input_ids`, each once."
  def batches_holding(input_ids) do
    from(membership in Learning.InputMembership,
      where: membership.input_id in ^input_ids,
      distinct: true,
      select: membership.batch_id
    )
  end

  @doc "The relearning batches whose chosen messages match one of `patterns`."
  def rebuilds_selecting(patterns) do
    from(batch in Learning.Batch,
      where: not is_nil(batch.rebuild_target_id),
      where: fragment("? LIKE ANY(?::text[])", batch.rebuild_selection, ^patterns),
      select: batch.id
    )
  end

  @doc """
  The `limit` latest attempts of `batch_ids`, and those prepared before
  batches whose own selection matches one of `patterns`.
  """
  def runs_of(batch_ids, patterns, limit) do
    from(run in Learning.LearningRun,
      where:
        run.batch_id in ^batch_ids or
          (is_nil(run.batch_id) and fragment("? LIKE ANY(?::text[])", run.inputs, ^patterns)),
      order_by: [desc: run.inserted_at, desc: run.id],
      limit: ^limit
    )
  end

  @doc "Every attempt of `batch_ids` in the order it began, as `{batch_id, run_id}`."
  def attempts_in_order(batch_ids) do
    from(run in Learning.LearningRun,
      where: run.batch_id in ^batch_ids,
      order_by: [asc: run.batch_id, asc: run.inserted_at, asc: run.id],
      select: {run.batch_id, run.id}
    )
  end

  @doc "The topic revisions the exact responses `result_refs` wrote, in the order they were written."
  def revisions_written(result_refs) do
    from(revision in Knowledge.KnowledgeRevision,
      where: revision.source_result_ref in ^result_refs,
      order_by: [asc: revision.inserted_at, asc: revision.version]
    )
  end
end
