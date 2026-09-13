defmodule Ryker.Repo.Migrations.NormalizeKnowledgeSources do
  use Ecto.Migration

  def up do
    # This pre-v1 cut deliberately resets derived topic heads/history. The
    # operator authorized a clean memory start. Ingress, execution/delivery,
    # confirmed memory and exposure fences are not deleted. Deployment must
    # retain a database backup and drain affected active model work first.
    execute("DELETE FROM #{table_name("conversation_knowledge")}")

    execute(
      "ALTER TABLE #{table_name("conversation_knowledge_sources")} DROP CONSTRAINT conversation_knowledge_sources_pkey"
    )

    alter table(:conversation_knowledge_sources) do
      add(:receipt_fingerprint, :text, null: false)
      add(:receipt, :text, null: false)
      add(:direct_support_version, :bigint)
    end

    execute(
      "ALTER TABLE #{table_name("conversation_knowledge_sources")} ADD PRIMARY KEY (knowledge_id, generation, receipt_fingerprint)"
    )

    create(
      index(:conversation_knowledge_sources, [:knowledge_id, :generation, :introduced_version])
    )

    # Point source joins must stay bounded even when stale observation
    # statistics choose observations as the outer relation. The leading
    # observation key also supports reverse-source revocation lookups.
    create(
      index(:conversation_knowledge_sources, [:observation_id, :knowledge_id, :generation],
        name: :knowledge_sources_observation_lookup
      )
    )

    create(
      constraint(:conversation_knowledge_sources, :knowledge_receipt_json,
        check: "pg_input_is_valid(receipt, 'jsonb')"
      )
    )

    # One non-recursive resolver for authorization and retention. An unknown,
    # missing or malformed reference produces NULL, which the owning validators
    # reject. Pruning prose must NOT erase its expiry roots: access checks reject
    # a pruned revision separately, while retention still follows these roots.
    execute("""
    CREATE FUNCTION #{table_name("responder_learning_roots")}(dependencies text)
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
      LEFT JOIN #{table_name("conversation_knowledge_revisions")} v
        ON d->>'kind' = 'knowledge_sources'
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
      LEFT JOIN #{table_name("conversation_knowledge_sources")} s
        ON s.knowledge_id = v.knowledge_id AND s.generation = v.source_generation
        AND s.introduced_version <= v.version
      WHERE coalesce(d ? 'knowledge_id', false)
    $function$
    """)
  end

  def down do
    raise "normalized memory cannot restore reset topic history; restore the qualified database backup"
  end

  defp table_name(name), do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{name}")
end
