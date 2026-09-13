defmodule Ryker.Repo.Migrations.OwnLearningFleetSessions do
  use Ecto.Migration

  def up do
    alter table(:episode_work_sessions) do
      add(:learning_run_id, references(:conversation_learning_runs, type: :uuid))
    end

    create(
      unique_index(:episode_work_sessions, [:learning_run_id],
        where: "execution_kind = 'learning'"
      )
    )

    create(
      unique_index(:episode_work_sessions, [:external_ref],
        where: "execution_kind = 'learning'",
        name: :learning_session_external_identity
      )
    )

    create(unique_index(:episode_work_sessions, [:id, :learning_run_id]))
    drop(constraint(:episode_work_sessions, :episode_work_session_owner_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_owner_valid,
        check:
          "(execution_kind = 'work' AND episode_id IS NOT NULL AND admission_input_id IS NULL AND learning_run_id IS NULL) OR " <>
            "(execution_kind = 'admission' AND episode_id IS NULL AND learning_run_id IS NULL AND repository_ref IS NULL " <>
            "AND repository_context IS NULL AND workspace_task IS NULL) OR " <>
            "(execution_kind = 'learning' AND episode_id IS NULL AND admission_input_id IS NULL AND learning_run_id IS NOT NULL " <>
            "AND repository_ref IS NULL AND repository_context IS NULL AND workspace_task IS NULL AND authority_digest IS NULL)"
      )
    )
  end

  def down, do: raise("Export learning session custody before reverting its owner constraint")
end
