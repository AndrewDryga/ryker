defmodule Ryker.Repo.Migrations.PreserveSourceEnvironments do
  use Ecto.Migration

  def up do
    for table <- [:conversation_learning_batches, :conversation_knowledge, :episode_case_records] do
      alter table(table) do
        add(:environment_ref, :string)
      end
    end

    for table <- [:conversation_knowledge, :episode_case_records] do
      alter table(table) do
        add(:environment_known, :boolean, null: false, default: false)
      end
    end

    flush()
    refuse_mixed_active_batches!()
    backfill_knowledge()
    backfill_batches()
    backfill_cases()

    for table <- [:conversation_knowledge, :episode_case_records] do
      table_name = Atom.to_string(table)

      execute(
        "ALTER TABLE #{qualified(table_name)} ALTER COLUMN environment_known SET DEFAULT true"
      )
    end

    rekey_batches(true)
    execute("DROP INDEX #{qualified("conversation_knowledge_scope_key_topic_key_index")}")

    execute(
      "CREATE UNIQUE INDEX conversation_knowledge_scope_key_topic_key_index ON #{qualified("conversation_knowledge")} (scope_key, environment_known, COALESCE(environment_ref, ''), topic_key)"
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("conversation_knowledge")} GROUP BY scope_key,topic_key HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'environment-specific topics exist; rollback would merge their identities';
      END IF;
      IF EXISTS (
        SELECT 1 FROM #{qualified("conversation_learning_batches")} b
        WHERE b.status IN ('queued','running') OR
          (b.status='deferred' AND EXISTS (
            SELECT 1 FROM #{qualified("conversation_learning_runs")} r
            WHERE r.batch_id=b.id AND r.started_at IS NOT NULL AND r.remote_stopped_at IS NULL
          ))
        GROUP BY b.transport,b.conversation_ref,b.repository_ref,b.execution_mode
        HAVING count(DISTINCT COALESCE(b.environment_ref,''))>1
      ) THEN
        RAISE EXCEPTION 'environment-specific active batches exist; rollback would merge their custody';
      END IF;
    END $$;
    """)

    execute("DROP INDEX #{qualified("conversation_knowledge_scope_key_topic_key_index")}")

    execute(
      "CREATE UNIQUE INDEX conversation_knowledge_scope_key_topic_key_index ON #{qualified("conversation_knowledge")} (scope_key, topic_key)"
    )

    rekey_batches(false)

    for table <- [:conversation_knowledge, :episode_case_records] do
      alter table(table) do
        remove(:environment_known)
      end
    end

    for table <- [:conversation_learning_batches, :conversation_knowledge, :episode_case_records] do
      alter table(table) do
        remove(:environment_ref)
      end
    end
  end

  defp refuse_mixed_active_batches! do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("conversation_learning_batches")} b
        JOIN (
          SELECT batch_id,input_id FROM #{qualified("conversation_learning_inputs")}
          UNION
          SELECT b.id,e.id FROM #{qualified("conversation_learning_batches")} b
          CROSS JOIN LATERAL jsonb_array_elements(COALESCE(b.rebuild_selection::jsonb,'[]'::jsonb)) selected
          JOIN #{qualified("ingress_inbox_entries")} e ON e.id::text=selected->>'source_input_id'
        ) m ON m.batch_id=b.id
        JOIN #{qualified("ingress_inbox_entries")} e ON e.id=m.input_id
        WHERE b.status IN ('queued','running','deferred')
        GROUP BY b.id HAVING count(DISTINCT COALESCE(e.work_profile::jsonb->>'environment_ref',''))>1
      ) THEN
        RAISE EXCEPTION 'active learning batch contains mixed environments; settle it before migration';
      END IF;
    END $$;
    """)
  end

  defp backfill_batches do
    execute("""
    UPDATE #{qualified("conversation_learning_batches")} b SET environment_ref=s.environment_ref
    FROM (
      SELECT m.batch_id, min(e.work_profile::jsonb->>'environment_ref') AS environment_ref
      FROM #{qualified("conversation_learning_inputs")} m JOIN #{qualified("ingress_inbox_entries")} e ON e.id=m.input_id
      GROUP BY m.batch_id HAVING count(DISTINCT COALESCE(e.work_profile::jsonb->>'environment_ref',''))=1
    ) s WHERE b.id=s.batch_id
    """)

    execute("""
    UPDATE #{qualified("conversation_learning_batches")} b SET environment_ref=k.environment_ref
    FROM #{qualified("conversation_knowledge")} k WHERE b.rebuild_target_id=k.id
    """)
  end

  defp backfill_knowledge do
    execute("""
    UPDATE #{qualified("conversation_knowledge")} k SET environment_ref=s.environment_ref,environment_known=true
    FROM (
      SELECT k.id, min(e.work_profile::jsonb->>'environment_ref') AS environment_ref
      FROM #{qualified("conversation_knowledge")} k
      JOIN #{qualified("conversation_knowledge_sources")} s ON s.knowledge_id=k.id AND s.generation=k.source_generation
      LEFT JOIN #{qualified("conversation_observations")} o ON o.id=s.observation_id AND o.revision=s.source_revision AND o.source_fingerprint=s.source_fingerprint
      LEFT JOIN #{qualified("ingress_inbox_entries")} e ON e.id=o.source_input_id
      WHERE s.direct_support_version IS NOT NULL
      GROUP BY k.id HAVING count(*)=count(e.id) AND count(DISTINCT COALESCE(e.work_profile::jsonb->>'environment_ref',''))=1
    ) s WHERE k.id=s.id
    """)
  end

  defp backfill_cases do
    execute("""
    UPDATE #{qualified("episode_case_records")} c SET environment_ref=s.environment_ref,environment_known=true
    FROM (
      SELECT DISTINCT ON (episode_id) episode_id, environment_ref
      FROM #{qualified("episode_work_sessions")} WHERE execution_kind='work'
      ORDER BY episode_id,generation DESC
    ) s WHERE c.episode_id=s.episode_id
    """)
  end

  # Scope hashes are flat canonical JSON. Keep their encoding inside this
  # migration, independent of future runtime changes to scope representation.
  defp rekey_batches(include_environment?) do
    flush()
    table = qualified("conversation_learning_batches")
    columns = ~w(conversation_ref execution_mode repository_ref transport)
    columns = if include_environment?, do: Enum.sort(["environment_ref" | columns]), else: columns
    result = repo().query!("SELECT id, #{Enum.join(columns, ", ")} FROM #{table}")

    for [id | values] <- result.rows do
      json =
        Enum.zip_with(columns, values, fn key, value ->
          Jason.encode!(key) <> ":" <> Jason.encode!(value)
        end)

      hash =
        :crypto.hash(:sha256, "{" <> Enum.join(json, ",") <> "}") |> Base.encode16(case: :lower)

      repo().query!("UPDATE #{table} SET scope_key=$1 WHERE id=$2", [hash, id])
    end
  end

  defp qualified(table),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{table}")
end
