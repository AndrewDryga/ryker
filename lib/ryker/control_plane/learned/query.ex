defmodule Ryker.ControlPlane.Learned.Query do
  @moduledoc """
  What the Learned page reads (`Ryker.ControlPlane.ConversationMemory`): its
  topics, conversation summaries and source notes, their search, how many
  sources each topic keeps, a topic's update history with the message each
  update came from, and when a summary's sources were said.
  """
  use Ryker, :query
  alias Ryker.Continuity
  alias Ryker.ControlPlane.Search
  alias Ryker.Ingress
  alias Ryker.Knowledge
  alias Ryker.Learning
  require Ryker.ControlPlane.Search

  @doc "Every row the page lists as `kind`, knowledge or context."
  def items("knowledge"), do: from(item in Knowledge.ConversationKnowledge)
  def items("context"), do: from(summary in Continuity.ConversationSummary)

  @doc "The source notes of `observation_ids` that still say something."
  def notes(observation_ids) do
    from(source in Learning.ConversationObservation,
      where: not is_nil(source.note) and source.id in ^observation_ids
    )
  end

  @doc "The one row `id` of a list."
  def only(queryable, id), do: from(item in queryable, where: item.id == ^id)

  @doc """
  The rows of a `kind` list that say `text`. What a topic or a summary says
  is searched, not its field names: searching the state as JSON text matched
  every row with a field of the name searched for (2026-10-04 review).
  """
  def matching(queryable, "knowledge", text) do
    from(item in queryable, where: Search.json_text_matches(item.state, ^Search.contains(text)))
  end

  def matching(queryable, "sources", text) do
    from(source in queryable,
      where: fragment("position(lower(?) in lower(?)) > 0", ^text, source.note)
    )
  end

  def matching(queryable, "context", text) do
    from(summary in queryable,
      where: Search.json_text_matches(summary.state, ^Search.contains(text))
    )
  end

  @doc """
  How many sources each of `knowledge_ids` keeps in its current generation,
  how many support it directly, and when the oldest was retained, as `{id,
  {count, direct, oldest_retained_at}}`.
  """
  def source_counts(knowledge_ids) do
    from(s in Knowledge.KnowledgeSource,
      join: k in Knowledge.ConversationKnowledge,
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
    from(r in Knowledge.KnowledgeRevision,
      left_join: entry in Ingress.Inbox.Entry,
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
    from(o in Learning.ConversationObservation,
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
