defmodule Ryker.Repo.Migrations.BoundReadsOfGrowingHistory do
  @moduledoc """
  Reads that grew with every day of history on the tenant install (2026-11-03).

  A topic stores the sources of the topics it was learned from, so citing
  topics repeats their receipts: 680 distinct receipts were stored 22,986
  times, and one summary expanded to 20,513 rows for 682 distinct sources.
  Every caller reads `ryker_learning_roots` as a set, so it returns each
  stored receipt once; an unresolvable reference still yields its NULL row.

  Retention bounds each rule by age, every minute, and these tables had no
  index on the age it bounds by, so each pass read every row ever kept. The
  latest monitoring refresh of a reply and the directly supporting sources of
  a topic were likewise found by reading the whole table.
  """
  use Ecto.Migration

  def up do
    execute(roots_function(:distinct))

    # The ready pools look for stranded and failed starts every second, and
    # retired sessions keep their pool state, so each look read every session.
    create(
      index(:episode_work_sessions, [:execution_kind, :ready_state, :inserted_at, :id],
        name: :episode_work_sessions_pool_state
      )
    )

    create(
      index(:episode_work_sessions, [:execution_kind, :inserted_at, :id],
        name: :episode_work_sessions_pool_recent
      )
    )

    create(index(:coop_worker_commands, [:updated_at, :id]))
    create(index(:coop_worker_events, [:inserted_at, :id]))
    create(index(:github_repository_events, [:inserted_at, :id]))
    create(index(:slack_thread_status_receipts, [:inserted_at, :id]))

    create(
      index(
        :slack_interaction_audit,
        [:workspace_ref, :channel_ref, :message_ref, "inserted_at DESC", "id DESC"],
        name: :slack_interaction_audit_latest_monitoring,
        where: "action_id = 'monitoring_status'"
      )
    )

    create(
      index(:conversation_knowledge_sources, [:knowledge_id, :generation],
        name: :conversation_knowledge_sources_direct_support,
        where: "direct_support_version IS NOT NULL"
      )
    )
  end

  def down do
    drop(
      index(:conversation_knowledge_sources, [],
        name: :conversation_knowledge_sources_direct_support
      )
    )

    drop(index(:slack_interaction_audit, [], name: :slack_interaction_audit_latest_monitoring))
    drop(index(:slack_thread_status_receipts, [:inserted_at, :id]))
    drop(index(:github_repository_events, [:inserted_at, :id]))
    drop(index(:coop_worker_events, [:inserted_at, :id]))
    drop(index(:coop_worker_commands, [:updated_at, :id]))
    drop(index(:episode_work_sessions, [], name: :episode_work_sessions_pool_recent))
    drop(index(:episode_work_sessions, [], name: :episode_work_sessions_pool_state))

    execute(roots_function(:every))
  end

  defp roots_function(receipts) do
    """
    CREATE OR REPLACE FUNCTION #{qualified("ryker_learning_roots")}(dependencies text) RETURNS SETOF jsonb
        LANGUAGE sql STABLE
        AS $$
      WITH parsed AS (
        SELECT CASE WHEN pg_input_is_valid(dependencies, 'jsonb')
          THEN dependencies::jsonb ELSE 'null'::jsonb END AS value
      ), descriptors AS (
        SELECT d FROM parsed,
          LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(value) = 'array'
            THEN value ELSE '[null]'::jsonb END) d
      )
      SELECT d FROM descriptors WHERE NOT coalesce(d ? 'knowledge_id', false)
      UNION ALL
      #{reference_receipts(receipts)}
    $$
    """
  end

  defp reference_receipts(:distinct) do
    """
    SELECT kept.receipt::jsonb FROM (
        SELECT DISTINCT s.receipt_fingerprint, s.receipt
        #{reference_sources()}
      ) AS kept
    """
  end

  defp reference_receipts(:every) do
    """
    SELECT s.receipt::jsonb
      #{reference_sources()}
    """
  end

  defp reference_sources do
    """
    FROM descriptors d
      LEFT JOIN LATERAL (
      SELECT v.knowledge_id, v.source_generation, v.version
      FROM #{qualified("conversation_knowledge_revisions")} v
      WHERE d->>'kind' = 'knowledge_sources'
      AND jsonb_typeof(d) = 'object'
      AND jsonb_typeof(d->'generation') = 'number'
      AND jsonb_typeof(d->'through_version') = 'number'
      AND (SELECT count(*) FROM jsonb_object_keys(CASE WHEN jsonb_typeof(d) = 'object'
        THEN d ELSE '{}'::jsonb END)) = 4
      AND v.knowledge_id = CASE WHEN pg_input_is_valid(d->>'knowledge_id', 'uuid')
        THEN (d->>'knowledge_id')::uuid ELSE NULL END
      AND v.source_generation = CASE WHEN pg_input_is_valid(d->>'generation', 'bigint')
        THEN (d->>'generation')::bigint ELSE NULL END
      AND v.version = CASE WHEN pg_input_is_valid(d->>'through_version', 'bigint')
        THEN (d->>'through_version')::bigint ELSE NULL END

      OFFSET 0
    ) v ON true

      LEFT JOIN #{qualified("conversation_knowledge_sources")} s
        ON s.knowledge_id = v.knowledge_id AND s.generation = v.source_generation
        AND s.introduced_version <= v.version
      WHERE coalesce(d ? 'knowledge_id', false)
    """
  end

  defp qualified(name),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{name}")
end
