defmodule Ryker.Repo.Migrations.AddWeeklyOperationalReviews do
  use Ecto.Migration

  def up do
    create table(:weekly_report_reviews, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:identity, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:settings_saved_at, :utc_datetime_usec)
      add(:period_start, :utc_datetime_usec, null: false)
      add(:period_end, :utc_datetime_usec, null: false)
      add(:timezone, :text, null: false)
      add(:deadline_at, :utc_datetime_usec, null: false)
      add(:status, :text, null: false)
      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:prompt, :text)
      add(:prompt_sha256, :text, null: false)
      add(:output_schema, :text)
      add(:manifest, :text)
      add(:recommendations, {:array, :map}, null: false, default: [])
      add(:source_identities, {:array, :text}, null: false, default: [])
      add(:message_keys, {:array, :text}, null: false, default: [])
      add(:source_turn_ids, {:array, :uuid}, null: false, default: [])
      add(:source_conversation_refs, {:array, :text}, null: false, default: [])
      add(:started_at, :utc_datetime_usec)
      add(:submit_revision, :integer)
      add(:coop_turn_id, :text)
      add(:candidate_attempt, :integer)
      add(:result, :text)
      add(:result_sha256, :text)
      add(:producer, :text)
      add(:validation_receipt, :text)
      add(:stop_receipt, :text)
      add(:remote_stopped_at, :utc_datetime_usec)
      add(:error_code, :text)
      add(:forgotten_at, :utc_datetime_usec)
      add(:pruned_at, :utc_datetime_usec)
      add(:lease_ref, :uuid)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:reconcile_attempt_count, :integer, null: false, default: 0)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:weekly_report_reviews, [:identity]))
    create(index(:weekly_report_reviews, [:next_attempt_at], where: "remote_stopped_at IS NULL"))

    create(
      constraint(:weekly_report_reviews, :weekly_report_reviews_state_valid,
        check: """
        period_start < period_end AND deadline_at >= period_end
        AND status IN ('prepared','responded','applied','rejected','stale')
        AND (submit_revision IS NULL OR submit_revision > 0)
        AND (candidate_attempt IS NULL OR candidate_attempt > 0)
        AND ((remote_stopped_at IS NULL) = (stop_receipt IS NULL))
        AND (status <> 'applied' OR (remote_stopped_at IS NOT NULL AND validation_receipt IS NOT NULL))
        AND ((lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
          OR (lease_ref IS NOT NULL AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL))
        AND reconcile_attempt_count >= 0
        """
      )
    )

    create(
      constraint(:weekly_report_reviews, :weekly_report_reviews_content_valid,
        check: """
        identity ~ '^[0-9a-f]{64}$' AND prompt_sha256 ~ '^[0-9a-f]{64}$'
        AND policy_digest ~ '^[0-9a-f]{64}$'
        AND char_length(policy) BETWEEN 1 AND 1024
        AND char_length(conversation_ref) BETWEEN 1 AND 1024
        AND (prompt IS NULL OR octet_length(prompt) BETWEEN 1 AND 131072)
        AND (result IS NULL OR octet_length(result) BETWEEN 1 AND 16384)
        AND cardinality(recommendations) <= 3
        AND cardinality(source_turn_ids) <= 80
        AND cardinality(source_conversation_refs) <= 80
        """
      )
    )

    alter table(:weekly_reports) do
      add(:review_id, references(:weekly_report_reviews, type: :uuid, on_delete: :nilify_all))
      add(:review_redacted_at, :utc_datetime_usec)
    end

    alter table(:episode_work_sessions) do
      add(
        :weekly_review_id,
        references(:weekly_report_reviews, type: :uuid, on_delete: :delete_all)
      )
    end

    create(unique_index(:episode_work_sessions, [:weekly_review_id]))

    execute("""
    DO $$ DECLARE old_check text; BEGIN
      SELECT pg_get_expr(conbin, conrelid) INTO STRICT old_check FROM pg_constraint
        WHERE conrelid = '#{qualified("episode_work_sessions")}'::regclass
          AND conname = 'episode_work_session_owner_valid';
      ALTER TABLE #{qualified("episode_work_sessions")} DROP CONSTRAINT episode_work_session_owner_valid;
      EXECUTE 'ALTER TABLE #{qualified("episode_work_sessions")} ADD CONSTRAINT episode_work_session_owner_valid CHECK ((weekly_review_id IS NULL AND (' || old_check || ')) OR (execution_kind = ''weekly_review'' AND weekly_review_id IS NOT NULL AND completion_review_id IS NULL AND episode_id IS NULL AND admission_input_id IS NULL AND learning_run_id IS NULL AND improvement_run_id IS NULL AND knowledge_run_id IS NULL AND repository_ref IS NULL AND repository_source IS NULL AND repository_context IS NULL AND workspace_task IS NULL AND authority_digest IS NULL AND emisar_connection_ref IS NULL AND environment_ref IS NULL AND ready_state IS NULL))';
      SELECT pg_get_expr(conbin, conrelid) INTO STRICT old_check FROM pg_constraint
        WHERE conrelid = '#{qualified("execution_usage")}'::regclass
          AND conname = 'execution_usage_identity_valid';
      ALTER TABLE #{qualified("execution_usage")} DROP CONSTRAINT execution_usage_identity_valid;
      old_check := replace(old_check, '''knowledge''::text', '''knowledge''::text, ''weekly_review''::text');
      EXECUTE 'ALTER TABLE #{qualified("execution_usage")} ADD CONSTRAINT execution_usage_identity_valid CHECK (' || old_check || ')';
    END $$;
    """)
  end

  def down do
    raise Ecto.MigrationError, "Restore the pre-deploy backup to preserve weekly review custody"
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      schema -> ~s("#{schema}"."#{table}")
    end
  end
end
