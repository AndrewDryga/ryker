defmodule Ryker.Repo.Migrations.WorkSessionsKeptReady do
  use Ecto.Migration

  # Work sessions kept ready (Settings › Advanced): a new conversation's first answer waited
  # 20-55 s for Coop to create its Work session (2026-10-11, 25 new sessions measured). A Work
  # session started ahead of time has no episode until exactly one conversation claims it, as a
  # routing session kept ready has no message: `starting` while Coop creates it, `ready` once it
  # is open, `claimed` by that conversation, or `retired` when it is given up unused and cleanup
  # closes it. Only an unclaimed one has no episode. A check passes on NULL, so a missing state is
  # tested for, not left to `= ANY`.

  @learning_improvement_knowledge """
  ((execution_kind = 'learning'::text) AND (episode_id IS NULL) AND (admission_input_id IS NULL) AND (learning_run_id IS NOT NULL) AND (improvement_run_id IS NULL) AND (knowledge_run_id IS NULL) AND (repository_ref IS NULL) AND (repository_context IS NULL) AND (workspace_task IS NULL) AND (authority_digest IS NULL))
  OR ((execution_kind = 'improvement'::text) AND (episode_id IS NULL) AND (admission_input_id IS NULL) AND (learning_run_id IS NULL) AND (improvement_run_id IS NOT NULL) AND (knowledge_run_id IS NULL) AND (repository_ref IS NULL) AND (repository_context IS NULL) AND (workspace_task IS NULL) AND (authority_digest IS NULL))
  OR ((execution_kind = 'knowledge'::text) AND (episode_id IS NULL) AND (admission_input_id IS NULL) AND (learning_run_id IS NULL) AND (improvement_run_id IS NULL) AND (knowledge_run_id IS NOT NULL) AND (repository_ref IS NOT NULL) AND (repository_source IS NOT NULL) AND (repository_context IS NULL) AND (workspace_task IS NULL) AND (authority_digest IS NULL))
  """

  @admission_owner """
  ((execution_kind = 'admission'::text) AND (episode_id IS NULL) AND (learning_run_id IS NULL) AND (improvement_run_id IS NULL) AND (knowledge_run_id IS NULL) AND (repository_ref IS NULL) AND (repository_context IS NULL) AND (workspace_task IS NULL))
  """

  @work_owner_with_episode """
  ((execution_kind = 'work'::text) AND (episode_id IS NOT NULL) AND (admission_input_id IS NULL) AND (learning_run_id IS NULL) AND (improvement_run_id IS NULL) AND (knowledge_run_id IS NULL))
  """

  @work_owner_or_kept_ready """
  ((execution_kind = 'work'::text) AND (admission_input_id IS NULL) AND (learning_run_id IS NULL) AND (improvement_run_id IS NULL) AND (knowledge_run_id IS NULL)
    AND ((episode_id IS NOT NULL) OR ((ready_state IS NOT NULL) AND (ready_state = ANY (ARRAY['starting'::text, 'ready'::text, 'retired'::text])) AND (workspace_task IS NULL))))
  """

  @admission_ready """
  ((execution_kind = 'admission'::text) AND (ready_state = ANY (ARRAY['starting'::text, 'ready'::text, 'claimed'::text, 'retired'::text])) AND ((ready_state = 'claimed'::text) OR (admission_input_id IS NULL)) AND ((ready_state <> 'ready'::text) OR (coop_session_id IS NOT NULL)))
  """

  @work_ready """
  ((execution_kind = 'work'::text) AND (ready_state = ANY (ARRAY['starting'::text, 'ready'::text, 'claimed'::text, 'retired'::text])) AND ((ready_state = 'claimed'::text) = (episode_id IS NOT NULL)) AND ((ready_state <> 'ready'::text) OR (coop_session_id IS NOT NULL)))
  """

  def up do
    alter table(:work_settings) do
      add(:ready_work_sessions, :integer, null: false, default: 2)
    end

    create(
      constraint(:work_settings, :work_settings_ready_work_sessions_valid,
        check: "ready_work_sessions BETWEEN 0 AND 5"
      )
    )

    replace(
      @work_owner_or_kept_ready,
      "ready_state IS NULL OR " <> @admission_ready <> " OR " <> @work_ready
    )
  end

  def down do
    # Without its episode an unclaimed Work session has no owner, and cleanup never closes a
    # session without one: it would stay open on the worker.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_work_sessions")}
        WHERE execution_kind = 'work' AND episode_id IS NULL AND cleanup_status <> 'discarded'
      ) THEN
        RAISE EXCEPTION 'Work sessions kept ready are still open; set Work sessions kept ready to 0 and let cleanup remove them before rolling back';
      END IF;
    END
    $$
    """)

    execute(
      "UPDATE #{qualified("episode_work_sessions")} SET ready_state = NULL WHERE execution_kind = 'work' AND ready_state = 'claimed'"
    )

    execute(
      "DELETE FROM #{qualified("episode_work_sessions")} WHERE execution_kind = 'work' AND episode_id IS NULL"
    )

    replace(@work_owner_with_episode, "ready_state IS NULL OR " <> @admission_ready)
    drop(constraint(:work_settings, :work_settings_ready_work_sessions_valid))

    alter table(:work_settings) do
      remove(:ready_work_sessions)
    end
  end

  defp replace(work_owner, ready_state) do
    drop(constraint(:episode_work_sessions, :episode_work_session_owner_valid))
    drop(constraint(:episode_work_sessions, :episode_work_session_ready_state_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_owner_valid,
        check:
          "(" <>
            work_owner <>
            " OR " <> @admission_owner <> " OR " <> @learning_improvement_knowledge <> ")"
      )
    )

    create(
      constraint(:episode_work_sessions, :episode_work_session_ready_state_valid,
        check: ready_state
      )
    )
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> "#{prefix}.#{table}"
    end
  end
end
