defmodule Ryker.Repo.Migrations.ExpandSourcesBeforeFiltering do
  @moduledoc """
  `ryker_learning_roots` returns each stored receipt once
  (20261103200000), but PostgreSQL pushed a caller's filter on the receipt
  below that de-duplication, so retention's expiry check still parsed every
  copy: 1.05 million receipt checks and 8.1 s of every minute on the tenant
  install (2026-11-03). Fenced, the copies are folded first and the check
  runs on each distinct receipt: 1.3 s on the same data.
  """
  use Ecto.Migration

  def up, do: execute(roots_function("OFFSET 0"))
  def down, do: execute(roots_function(""))

  defp roots_function(fence) do
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
      SELECT kept.receipt::jsonb FROM (
          SELECT DISTINCT s.receipt_fingerprint, s.receipt
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
          #{fence}
        ) AS kept
    $$
    """
  end

  defp qualified(name),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{name}")
end
