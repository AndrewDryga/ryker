defmodule Ryker.Knowledge.KnowledgeExposureQuery do
  @moduledoc "The topic revisions each Work session was shown, for every read of `episode_work_knowledge_exposures`."
  import Ecto.Query
  alias Ryker.Knowledge.{KnowledgeExposure, KnowledgeRevision}

  def all, do: from(exposures in KnowledgeExposure, as: :episode_work_knowledge_exposures)

  def by_session_id(queryable \\ all(), session_id),
    do: where(queryable, [episode_work_knowledge_exposures: e], e.session_id == ^session_id)

  def in_topic_order(queryable) do
    order_by(queryable, [episode_work_knowledge_exposures: e],
      asc: e.knowledge_id,
      asc: e.version
    )
  end

  @doc """
  What sessions `session_ids` other than `session_id` were shown, once per
  revision, as the rows that record it for `session_id`'s turn `turn_id`.
  """
  def inherited_by(session_ids, session_id, turn_id) do
    from(e in all(),
      where: e.session_id in ^session_ids and e.session_id != ^session_id,
      distinct: [e.knowledge_id, e.version],
      select: %{
        session_id: type(^session_id, :binary_id),
        turn_id: type(^turn_id, :binary_id),
        knowledge_id: e.knowledge_id,
        version: e.version,
        inserted_at: fragment("clock_timestamp()")
      }
    )
  end

  @doc """
  What session `session_id` was shown, in topic order, as `{knowledge_id,
  source_generation, version}`; the generation is nil once the revision is gone.
  """
  def with_generations(session_id) do
    from(e in by_session_id(session_id),
      left_join: r in KnowledgeRevision,
      on: r.knowledge_id == e.knowledge_id and r.version == e.version,
      order_by: [asc: e.knowledge_id, asc: e.version],
      select: {e.knowledge_id, r.source_generation, e.version}
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
