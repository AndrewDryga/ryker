defmodule Responder.State.KnowledgeRetention do
  @moduledoc false
  alias Responder.{CanonicalJSON, Repo}

  # An aggregate depends on all sources in its generation. Expiring one source
  # withdraws that generation's copied text, but preserves revision receipts.
  def prune_in_transaction(seconds) do
    %{num_rows: count} =
      Repo.query!(
        """
        WITH candidates AS MATERIALIZED (
          SELECT k.id FROM conversation_knowledge k
          WHERE EXISTS (
            SELECT 1 FROM conversation_knowledge_sources s
            WHERE s.knowledge_id = k.id AND s.source_note IS NOT NULL
              AND s.retained_at < clock_timestamp() - ($1 * interval '1 second')
          ) OR EXISTS (
            SELECT 1 FROM conversation_knowledge_revisions r
            WHERE r.knowledge_id = k.id AND r.state::jsonb <> '{"retention":"pruned"}'::jsonb
              AND #{expired_sources("r")}
          )
          ORDER BY k.id LIMIT 100 FOR UPDATE SKIP LOCKED
        ), expired AS MATERIALIZED (
          SELECT DISTINCT s.knowledge_id, s.generation
          FROM conversation_knowledge_sources s JOIN candidates c ON c.id = s.knowledge_id
          WHERE s.source_note IS NOT NULL
            AND s.retained_at < clock_timestamp() - ($1 * interval '1 second')
          UNION
          SELECT r.knowledge_id, r.source_generation
          FROM conversation_knowledge_revisions r JOIN candidates c ON c.id = r.knowledge_id
          WHERE r.state::jsonb <> '{"retention":"pruned"}'::jsonb AND #{expired_sources("r")}
        ), sources AS (
          UPDATE conversation_knowledge_sources s SET source_note = NULL
          FROM expired e WHERE s.knowledge_id = e.knowledge_id AND s.generation = e.generation
          RETURNING s.knowledge_id
        ), revisions AS (
          UPDATE conversation_knowledge_revisions r SET state = '{"retention":"pruned"}'
          FROM expired e WHERE r.knowledge_id = e.knowledge_id AND r.source_generation = e.generation
          RETURNING r.knowledge_id
        )
        UPDATE conversation_knowledge k SET state = '{"retention":"pruned"}'
        FROM expired e WHERE k.id = e.knowledge_id AND k.source_generation = e.generation
        """,
        [seconds]
      )

    count + prune_observations(seconds) +
      Enum.sum(
        for table <- ~w(conversation_summaries conversation_rollups),
            do: prune_summary(table, seconds)
      )
  end

  defp prune_observations(seconds) do
    Repo.query!(
      """
      WITH candidates AS (
        SELECT o.id FROM conversation_observations o
        WHERE o.note IS NOT NULL AND #{expired_sources("o")}
        ORDER BY o.id LIMIT 100 FOR UPDATE SKIP LOCKED
      )
      UPDATE conversation_observations o SET note = NULL
      FROM candidates c WHERE o.id = c.id
      """,
      [seconds]
    ).num_rows
  end

  defp prune_summary(table, seconds) do
    # Only fixed table names from above enter this query. Preserve identity and
    # source fences; copied prose expires even when the summary itself is new.
    Repo.query!(
      """
      WITH candidates AS (
        SELECT m.id FROM #{table} m
        WHERE m.state::jsonb <> '{"retention":"pruned"}'::jsonb AND #{expired_sources("m")}
        ORDER BY m.id LIMIT 100 FOR UPDATE SKIP LOCKED
      )
      UPDATE #{table} m SET state = '{"retention":"pruned"}', state_fingerprint = $2
      FROM candidates c WHERE m.id = c.id
      """,
      [seconds, CanonicalJSON.digest(%{"retention" => "pruned"})]
    ).num_rows
  end

  defp expired_sources(binding) do
    """
    EXISTS (
      SELECT 1 FROM jsonb_array_elements(COALESCE(#{binding}.source_dependencies, '[]')::jsonb) receipt
      WHERE (receipt->>'retained_at')::timestamptz < clock_timestamp() - ($1 * interval '1 second')
    )
    """
  end
end
