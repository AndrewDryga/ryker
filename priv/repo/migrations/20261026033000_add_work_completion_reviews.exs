defmodule Ryker.Repo.Migrations.AddWorkCompletionReviews do
  use Ecto.Migration

  def up do
    create table(:work_completion_reviews, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:turn_id, references(:episode_work_turns, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:generation, :integer, null: false)
      add(:candidate_sha256, :text, null: false)
      add(:ledger_sha256, :text, null: false)
      add(:progress_sha256, :text, null: false)
      add(:status, :text, null: false)
      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:prompt, :text)
      add(:prompt_sha256, :text, null: false)
      add(:output_schema, :text)
      add(:started_at, :utc_datetime_usec, null: false)
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
      add(:pruned_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:work_completion_reviews, [:turn_id, :generation]))

    create(
      constraint(:work_completion_reviews, :work_completion_reviews_state_valid,
        check: """
        generation > 0 AND status IN ('prepared','responded','applied','rejected','stale')
        AND (submit_revision IS NULL OR submit_revision > 0)
        AND (candidate_attempt IS NULL OR candidate_attempt > 0)
        AND ((remote_stopped_at IS NULL) = (stop_receipt IS NULL))
        AND (status <> 'applied' OR (remote_stopped_at IS NOT NULL AND validation_receipt IS NOT NULL))
        """
      )
    )

    create(
      constraint(:work_completion_reviews, :work_completion_reviews_content_valid,
        check: """
        candidate_sha256 ~ '^[0-9a-f]{64}$' AND ledger_sha256 ~ '^[0-9a-f]{64}$'
        AND progress_sha256 ~ '^[0-9a-f]{64}$' AND prompt_sha256 ~ '^[0-9a-f]{64}$'
        AND policy_digest ~ '^[0-9a-f]{64}$' AND char_length(policy) BETWEEN 1 AND 1024
        AND (prompt IS NULL OR octet_length(prompt) BETWEEN 1 AND 524288)
        AND (result IS NULL OR octet_length(result) BETWEEN 1 AND 524288)
        AND (coop_turn_id IS NULL OR char_length(coop_turn_id) BETWEEN 1 AND 1024)
        AND (error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 120)
        """
      )
    )

    alter table(:episode_work_sessions) do
      add(
        :completion_review_id,
        references(:work_completion_reviews, type: :uuid, on_delete: :delete_all)
      )
    end

    create(unique_index(:episode_work_sessions, [:completion_review_id]))

    # Preserve every earlier owner invariant, including ready Work sessions. The new
    # execution owns only a review, with no repository, connector, episode or workspace.
    execute("""
    DO $$ DECLARE old_check text; BEGIN
      SELECT pg_get_expr(conbin, conrelid) INTO STRICT old_check FROM pg_constraint
        WHERE conrelid = '#{qualified("episode_work_sessions")}'::regclass
          AND conname = 'episode_work_session_owner_valid';
      ALTER TABLE #{qualified("episode_work_sessions")} DROP CONSTRAINT episode_work_session_owner_valid;
      EXECUTE 'ALTER TABLE #{qualified("episode_work_sessions")} ADD CONSTRAINT episode_work_session_owner_valid CHECK ((completion_review_id IS NULL AND (' || old_check || ')) OR (execution_kind = ''completion_review'' AND completion_review_id IS NOT NULL AND episode_id IS NULL AND admission_input_id IS NULL AND learning_run_id IS NULL AND improvement_run_id IS NULL AND knowledge_run_id IS NULL AND repository_ref IS NULL AND repository_source IS NULL AND repository_context IS NULL AND workspace_task IS NULL AND authority_digest IS NULL AND emisar_connection_ref IS NULL AND environment_ref IS NULL AND ready_state IS NULL))';
      SELECT pg_get_expr(conbin, conrelid) INTO STRICT old_check FROM pg_constraint
        WHERE conrelid = '#{qualified("execution_usage")}'::regclass
          AND conname = 'execution_usage_identity_valid';
      ALTER TABLE #{qualified("execution_usage")} DROP CONSTRAINT execution_usage_identity_valid;
      old_check := replace(old_check, '''knowledge''::text', '''knowledge''::text, ''completion_review''::text');
      EXECUTE 'ALTER TABLE #{qualified("execution_usage")} ADD CONSTRAINT execution_usage_identity_valid CHECK (' || old_check || ')';
    END $$;
    """)
  end

  def down do
    raise Ecto.MigrationError,
          "Restore the pre-deploy backup to preserve completion-review custody"
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      schema -> ~s("#{schema}"."#{table}")
    end
  end
end
