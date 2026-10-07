defmodule Ryker.ControlPlane.LearnedQuery do
  @moduledoc """
  What the Learned page reads (`Ryker.ControlPlane.ConversationMemory`): its
  topics, conversation summaries and source notes, their search, how many
  sources each topic keeps, a topic's update history with the message each
  update came from, and when a summary's sources were said.
  """
  import Ecto.Query
  require Ryker.ControlPlane.Search
  alias Ryker.Continuity.ConversationSummary
  alias Ryker.ControlPlane.Search
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.{ConversationKnowledge, KnowledgeRevision, KnowledgeSource}
  alias Ryker.Learning.ConversationObservation

  @doc "Every row the page lists as `kind`, knowledge or context."
  def items("knowledge"), do: from(item in ConversationKnowledge)
  def items("context"), do: from(summary in ConversationSummary)

  @doc "The source notes of `observation_ids` that still say something."
  def notes(observation_ids) do
    from(source in ConversationObservation,
      where: not is_nil(source.note) and source.id in ^observation_ids
    )
  end

  @doc "The one row `id` of a list."
  def only(query, id), do: from(item in query, where: item.id == ^id)

  @doc """
  The rows of a `kind` list that say `text`. What a topic or a summary says
  is searched, not its field names: searching the state as JSON text matched
  every row with a field of the name searched for (2026-10-04 review).
  """
  def matching(query, "knowledge", text),
    do: from(item in query, where: Search.json_text_matches(item.state, ^Search.contains(text)))

  def matching(query, "sources", text) do
    from(source in query,
      where: fragment("position(lower(?) in lower(?)) > 0", ^text, source.note)
    )
  end

  def matching(query, "context", text) do
    from(summary in query,
      where: Search.json_text_matches(summary.state, ^Search.contains(text))
    )
  end

  @doc """
  How many sources each of `knowledge_ids` keeps in its current generation,
  how many support it directly, and when the oldest was retained, as `{id,
  {count, direct, oldest_retained_at}}`.
  """
  def source_counts(knowledge_ids) do
    from(s in KnowledgeSource,
      join: k in ConversationKnowledge,
      on: k.id == s.knowledge_id and k.source_generation == s.generation,
      where: k.id in ^knowledge_ids,
      group_by: k.id,
      select:
        {k.id, {count(s.observation_id), count(s.direct_support_version), min(s.retained_at)}}
    )
  end

  @doc """
  Topic `knowledge_id`'s revisions, each with where the message it came from
  was said, as `{revision, transport, conversation_ref, source_item_ref}`.
  """
  def history(knowledge_id) do
    from(r in KnowledgeRevision,
      left_join: entry in Entry,
      on: entry.id == r.source_input_id,
      where: r.knowledge_id == ^knowledge_id,
      select:
        {r, entry.destination_transport, entry.destination_conversation_ref,
         entry.source_item_ref}
    )
  end

  @doc """
  When the latest of the exact retained source revisions `roots` names was
  said, `roots` being the canonical JSON of a summary's dependencies. A source
  edited since must not substitute today's message time.
  """
  def latest_source_at(roots) do
    from(o in ConversationObservation,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM ryker_learning_roots(?::text) r WHERE r->>'observation_id' = ?::text AND r->>'revision' = ?::text AND r->>'fingerprint' = ?)",
          ^roots,
          o.id,
          o.revision,
          o.source_fingerprint
        ),
      select: max(o.occurred_at)
    )
  end
end
