defmodule Responder.Repo.Migrations.BoundCompactSourceRevisionLookups do
  use Ecto.Migration

  def up do
    # With stale revision statistics, PostgreSQL expanded every historical
    # revision's memberships before selecting the requested descriptor. Pin the
    # exact revision lookup before expansion; no retained data is changed.
    execute(function_sql(:bounded))
  end

  def down do
    execute(function_sql(:original))
  end

  defp function_sql(lookup) do
    """
    CREATE OR REPLACE FUNCTION #{table_name("responder_learning_roots")}(dependencies text)
    RETURNS SETOF jsonb LANGUAGE sql STABLE AS $function$
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
      SELECT s.receipt::jsonb
      FROM descriptors d
      #{revision_lookup(lookup)}
      LEFT JOIN #{table_name("conversation_knowledge_sources")} s
        ON s.knowledge_id = v.knowledge_id AND s.generation = v.source_generation
        AND s.introduced_version <= v.version
      WHERE coalesce(d ? 'knowledge_id', false)
    $function$
    """
  end

  defp revision_lookup(:bounded) do
    """
    LEFT JOIN LATERAL (
      SELECT v.knowledge_id, v.source_generation, v.version
      FROM #{table_name("conversation_knowledge_revisions")} v
      WHERE #{revision_predicate()}
      OFFSET 0
    ) v ON true
    """
  end

  defp revision_lookup(:original) do
    """
    LEFT JOIN #{table_name("conversation_knowledge_revisions")} v
      ON #{revision_predicate()}
    """
  end

  defp revision_predicate do
    """
    d->>'kind' = 'knowledge_sources'
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
    """
  end

  defp table_name(name), do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{name}")
end
