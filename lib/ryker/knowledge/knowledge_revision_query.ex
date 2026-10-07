defmodule Ryker.Knowledge.KnowledgeRevisionQuery do
  @moduledoc "Every version of each topic, for every read of `conversation_knowledge_revisions`."
  import Ecto.Query
  alias Ryker.Knowledge.{ConversationKnowledge, KnowledgeRevision}

  def all, do: from(revisions in KnowledgeRevision, as: :conversation_knowledge_revisions)

  def by_knowledge_id(queryable \\ all(), knowledge_id),
    do: where(queryable, [conversation_knowledge_revisions: r], r.knowledge_id == ^knowledge_id)

  def by_knowledge_ids(queryable \\ all(), knowledge_ids),
    do: where(queryable, [conversation_knowledge_revisions: r], r.knowledge_id in ^knowledge_ids)

  def by_version(queryable, version),
    do: where(queryable, [conversation_knowledge_revisions: r], r.version == ^version)

  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")

  def in_version_order(queryable),
    do: order_by(queryable, [conversation_knowledge_revisions: r], asc: r.version)

  @doc """
  Revision `version` of topic `knowledge_id` within its `generation`, while
  that generation is the topic's current one and the revision keeps its words.
  """
  def current_reference(knowledge_id, generation, version) do
    from(r in all(),
      join: head in ConversationKnowledge,
      on: head.id == r.knowledge_id and head.source_generation == r.source_generation,
      where:
        r.knowledge_id == ^knowledge_id and r.source_generation == ^generation and
          r.version == ^version,
      where: fragment(~s(?::jsonb <> '{"retention":"pruned"}'::jsonb), r.state)
    )
  end
end
