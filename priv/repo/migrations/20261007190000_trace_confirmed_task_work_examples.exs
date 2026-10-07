defmodule Ryker.Repo.Migrations.TraceConfirmedTaskWorkExamples do
  use Ecto.Migration

  # A task confirmed from a card starts a request no message asked, so its Work
  # example named no message, and forgetting the message the task was offered
  # in never reached it (2026-10-04 review; on 2026-10-07, 32 of the 47
  # examples of confirmed tasks named none). New examples trace the request the
  # task was offered in (`Ryker.WorkExamples`). Each kept one takes the
  # message identities, keys and conversations that request's own routing and
  # Work examples hold, up the chain of requests each was confirmed from, and
  # one whose source a person already made Ryker forget is erased as that
  # forget would have erased it. Plain SQL over stored values, so the
  # migration means the same whenever it runs.

  @chain """
  WITH RECURSIVE chain AS (
    SELECT example.id AS example_id, episode.linked_episode_id AS source_id, 1 AS depth
    FROM work_examples AS example
    JOIN episode_kernel_episodes AS episode ON episode.id = example.episode_id
    WHERE episode.linked_episode_id IS NOT NULL AND example.forgotten_at IS NULL
    UNION ALL
    SELECT chain.example_id, episode.linked_episode_id, chain.depth + 1
    FROM chain
    JOIN episode_kernel_episodes AS episode ON episode.id = chain.source_id
    WHERE episode.linked_episode_id IS NOT NULL AND chain.depth < 8
  ), sources AS (
    SELECT chain.example_id, ARRAY[routing.source_identity] AS identities,
      routing.message_keys AS keys, routing.conversation_refs AS conversations,
      routing.forgotten_at IS NOT NULL AS forgotten
    FROM chain JOIN routing_examples AS routing ON routing.episode_id = chain.source_id
    UNION ALL
    SELECT chain.example_id, work.source_identities, work.message_keys, work.conversation_refs,
      work.forgotten_at IS NOT NULL
    FROM chain JOIN work_examples AS work ON work.episode_id = chain.source_id
  )
  """

  def up do
    execute("""
    #{@chain}
    UPDATE work_examples AS example
    SET source_identities = traced.identities,
        message_keys = traced.keys,
        conversation_refs = traced.conversations,
        updated_at = now()
    FROM (
      SELECT example.id,
        #{merged("source_identities", "identities")} AS identities,
        #{merged("message_keys", "keys")} AS keys,
        #{merged("conversation_refs", "conversations")} AS conversations
      FROM work_examples AS example
      WHERE example.id IN (SELECT example_id FROM sources)
    ) AS traced
    WHERE example.id = traced.id
    """)

    execute("""
    #{@chain}
    DELETE FROM work_example_feedback
    WHERE example_id IN (SELECT example_id FROM sources WHERE forgotten)
    """)

    execute("""
    #{@chain}
    UPDATE work_examples
    SET briefing = NULL, context = NULL, output_schema = NULL, trajectory = NULL,
        result = NULL, rejected_results = NULL, outcome = NULL, usage = NULL,
        forgotten_at = now(), updated_at = now()
    WHERE id IN (SELECT example_id FROM sources WHERE forgotten)
    """)
  end

  # The example's own values with its sources', each once, in byte order as
  # the copy sorts them.
  defp merged(own, traced) do
    """
    ARRAY(
      SELECT value FROM (
        SELECT DISTINCT value
        FROM unnest(example.#{own} || coalesce(
          (SELECT array_agg(value) FROM sources, unnest(sources.#{traced}) AS value
           WHERE sources.example_id = example.id),
          '{}')) AS value
        WHERE value IS NOT NULL
      ) AS distinct_values
      ORDER BY value COLLATE "C"
    )
    """
  end

  # The traced values are the same messages the source examples name, and an
  # example erased for its source was erased as the forget asked; neither is
  # put back.
  def down, do: :ok
end
