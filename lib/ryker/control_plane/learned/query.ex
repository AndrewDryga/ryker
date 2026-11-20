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

  @doc "Fields shown on a directory row, before its source history is checked."
  def summary_directory(query) do
    from(s in query,
      select:
        struct(s, [
          :id,
          :state,
          :updated_at,
          :transport,
          :conversation_ref,
          :repository_ref,
          :source_episode_id,
          :compaction_error_code,
          :compaction_retry_at
        ])
    )
  end

  def summary_histories(ids) do
    from(s in Continuity.ConversationSummary,
      where: s.id in ^ids,
      select: {s.id, s.updated_at, s.source_dependencies}
    )
  end

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

  @doc "Counts sources and direct support at the generation and revision shown on each topic row."
  def source_counts(topics) do
    heads = Enum.map(topics, &Map.take(&1, [:id, :source_generation, :version]))
    types = %{id: :binary_id, source_generation: :integer, version: :integer}

    from(k in values(heads, types),
      join: s in Knowledge.KnowledgeSource,
      on:
        k.id == s.knowledge_id and k.source_generation == s.generation and
          s.introduced_version <= k.version,
      group_by: k.id,
      select:
        {k.id,
         {count(s.observation_id),
          filter(count(s.observation_id), s.direct_support_version <= k.version),
          min(s.retained_at)}}
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
  said, `roots` being the canonical JSON of already expanded terminal receipts. A source
  edited since must not substitute today's message time.
  """
  def latest_source_at(roots) do
    # Probe only the rows named by the resolved frozen receipts.
    # The lateral boundary keeps a broad table scan out of a short receipt list.
    from(
      source in fragment(
        """
        SELECT matched.occurred_at FROM jsonb_array_elements(?::text::jsonb) root
        JOIN LATERAL (
          SELECT o.occurred_at FROM conversation_observations o
          WHERE o.id = CASE WHEN pg_input_is_valid(root->>'observation_id', 'uuid')
            THEN (root->>'observation_id')::uuid END
            AND o.id::text = root->>'observation_id'
            AND o.revision::text = root->>'revision'
            AND o.source_fingerprint = root->>'fingerprint'
          OFFSET 0
        ) matched ON true
        """,
        ^roots
      ),
      select: type(max(source.occurred_at), :utc_datetime_usec)
    )
  end
end
