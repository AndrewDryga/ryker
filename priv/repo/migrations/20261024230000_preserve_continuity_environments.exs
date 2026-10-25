defmodule Ryker.Repo.Migrations.PreserveContinuityEnvironments do
  use Ecto.Migration

  @tables [:conversation_observations, :conversation_summaries, :conversation_rollups]

  def up do
    for name <- @tables do
      alter table(name) do
        add(:environment_ref, :string)
        add(:environment_known, :boolean, null: false, default: false)
      end
    end

    flush()

    execute("""
    UPDATE #{qualified("conversation_observations")} o
      SET environment_ref=e.work_profile::jsonb->>'environment_ref', environment_known=true
    FROM #{qualified("ingress_inbox_entries")} e
    WHERE e.id=o.source_input_id AND e.revision=o.revision AND e.event_fingerprint=o.source_fingerprint
      AND e.operational_pruned_at IS NULL
    """)

    for name <- ~w(conversation_summaries conversation_rollups) do
      backfill_derived(name)
    end

    execute("DROP INDEX #{qualified("conversation_summaries_identity_key_index")}")
    execute("DROP INDEX #{qualified("conversation_rollups_identity")}")

    create(
      unique_index(
        :conversation_summaries,
        [:identity_key, :environment_known, :environment_ref],
        name: :conversation_summaries_identity_key_index,
        nulls_distinct: false
      )
    )

    create(
      unique_index(
        :conversation_rollups,
        [
          :workspace_ref,
          :scope_kind,
          :scope_ref,
          :period_start,
          :environment_known,
          :environment_ref
        ],
        name: :conversation_rollups_identity,
        nulls_distinct: false
      )
    )

    for name <- @tables do
      table_name = Atom.to_string(name)

      execute(
        "ALTER TABLE #{qualified(table_name)} ALTER COLUMN environment_known SET DEFAULT true"
      )
    end
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("conversation_summaries")} GROUP BY identity_key HAVING count(*)>1)
        OR EXISTS (SELECT 1 FROM #{qualified("conversation_rollups")}
          GROUP BY workspace_ref,scope_kind,scope_ref,period_start HAVING count(*)>1) THEN
        RAISE EXCEPTION 'environment-specific continuity exists; rollback would merge history';
      END IF;
    END $$;
    """)

    execute("DROP INDEX #{qualified("conversation_summaries_identity_key_index")}")
    execute("DROP INDEX #{qualified("conversation_rollups_identity")}")
    create(unique_index(:conversation_summaries, [:identity_key]))

    create(
      unique_index(
        :conversation_rollups,
        [:workspace_ref, :scope_kind, :scope_ref, :period_start],
        name: :conversation_rollups_identity
      )
    )

    for name <- @tables do
      alter table(name) do
        remove(:environment_known)
        remove(:environment_ref)
      end
    end
  end

  # A retained original receipt proves provenance; today's channel settings do not.
  # Missing, replaced or mixed roots leave historical prose intact and unknown.
  defp backfill_derived(table_name) do
    execute("""
    UPDATE #{qualified(table_name)} m SET environment_ref=s.environment_ref, environment_known=true
    FROM (
      SELECT m.id,min(o.environment_ref) AS environment_ref
      FROM #{qualified(table_name)} m
      CROSS JOIN LATERAL #{qualified("ryker_learning_roots")}(m.source_dependencies) root
      LEFT JOIN #{qualified("conversation_observations")} o
        ON o.id=CASE WHEN pg_input_is_valid(root->>'observation_id','uuid') THEN (root->>'observation_id')::uuid ELSE NULL END
        AND o.environment_known AND o.source_input_id::text=root->>'source_input_id'
        AND o.revision::text=root->>'revision' AND o.source_fingerprint=root->>'fingerprint'
        AND o.workspace_ref=root->>'workspace_ref' AND o.transport=root->>'transport'
        AND o.conversation_ref=root->>'conversation_ref'
        AND o.repository_ref IS NOT DISTINCT FROM root->>'repository_ref'
      GROUP BY m.id HAVING count(*)=count(o.id)
        AND count(DISTINCT COALESCE(o.environment_ref,''))=1
    ) s WHERE m.id=s.id AND #{producer_agrees(table_name)}
    """)
  end

  # Exact producing sessions may contradict the roots; never relabel their prose.
  defp producer_agrees("conversation_summaries") do
    """
    (m.source_turn_id IS NULL OR EXISTS (
      SELECT 1 FROM #{qualified("episode_work_turns")} t
      JOIN #{qualified("episode_work_sessions")} w ON w.id=t.session_id
      WHERE t.id=m.source_turn_id AND t.episode_id=m.source_episode_id
        AND w.episode_id=m.source_episode_id
        AND w.environment_ref IS NOT DISTINCT FROM s.environment_ref
    ))
    """
  end

  defp producer_agrees("conversation_rollups"), do: "true"

  defp qualified(table),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{table}")
end
