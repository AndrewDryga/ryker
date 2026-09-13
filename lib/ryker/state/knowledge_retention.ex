defmodule Ryker.State.KnowledgeRetention do
  @moduledoc false
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.State.LearningSources

  # An inherited-only root matters just as much as a direct citation. Withdraw
  # only revisions that actually inherited it; earlier revisions keep their history.
  def prune_in_transaction(seconds) do
    %{num_rows: count} =
      Repo.query!(
        """
        WITH candidates AS MATERIALIZED (
          SELECT k.id FROM conversation_knowledge k
          WHERE EXISTS (
            SELECT 1 FROM conversation_knowledge_sources s
            WHERE s.knowledge_id = k.id
              AND s.retained_at < clock_timestamp() - ($1 * interval '1 second')
              AND (s.source_note IS NOT NULL OR EXISTS (
                SELECT 1 FROM conversation_knowledge_revisions r
                WHERE r.knowledge_id = s.knowledge_id AND r.source_generation = s.generation
                  AND r.version >= s.introduced_version
                  AND r.state::jsonb <> '{"retention":"pruned"}'::jsonb
              ))
          )
          ORDER BY k.id LIMIT 100 FOR UPDATE SKIP LOCKED
        ), expired AS MATERIALIZED (
          SELECT s.knowledge_id, s.generation, min(s.introduced_version) AS first_version
          FROM conversation_knowledge_sources s JOIN candidates c ON c.id = s.knowledge_id
          WHERE s.retained_at < clock_timestamp() - ($1 * interval '1 second')
          GROUP BY s.knowledge_id, s.generation
        ), sources AS (
          UPDATE conversation_knowledge_sources s SET source_note = NULL
          FROM expired e WHERE s.knowledge_id = e.knowledge_id AND s.generation = e.generation
          RETURNING s.knowledge_id
        ), revisions AS (
          UPDATE conversation_knowledge_revisions r SET state = '{"retention":"pruned"}'
          FROM expired e WHERE r.knowledge_id = e.knowledge_id AND r.source_generation = e.generation
            AND r.version >= e.first_version
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
      [seconds, LearningSources.utc_timestamp_pattern()]
    ).num_rows
  end

  defp prune_summary(table, seconds) do
    # Only fixed table names from above enter this query. Preserve identity and
    # source fences; copied prose expires even when the summary itself is new.
    Repo.query!(
      """
      WITH candidates AS (
        SELECT m.id FROM #{table} m
        WHERE (m.state::jsonb = '{"retention":"pruned"}'::jsonb AND
            m.source_dependencies IS DISTINCT FROM '[]') OR
          (m.state::jsonb <> '{"retention":"pruned"}'::jsonb AND #{expired_sources("m")})
        ORDER BY m.id LIMIT 100 FOR UPDATE SKIP LOCKED
      )
      UPDATE #{table} m SET state = '{"retention":"pruned"}', state_fingerprint = $3,
        source_dependencies = '[]'
      FROM candidates c WHERE m.id = c.id
      """,
      [
        seconds,
        LearningSources.utc_timestamp_pattern(),
        CanonicalJSON.digest(%{"retention" => "pruned"})
      ]
    ).num_rows
  end

  defp expired_sources(binding) do
    """
    EXISTS (
      SELECT 1 FROM responder_learning_roots(#{binding}.source_dependencies) receipt
      WHERE CASE WHEN receipt->>'retained_at' ~ $2
        AND pg_input_is_valid(replace(receipt->>'retained_at', ',', '.'), 'timestamptz') THEN
        replace(receipt->>'retained_at', ',', '.')::timestamptz < clock_timestamp() - ($1 * interval '1 second')
        ELSE false END
    )
    """
  end
end
