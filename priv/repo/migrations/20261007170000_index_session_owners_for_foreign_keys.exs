defmodule Ryker.Repo.Migrations.IndexSessionOwnersForForeignKeys do
  use Ecto.Migration

  # A learning, improvement or knowledge run has one session, and a routing
  # generation of an inbox entry has one session; the unique indexes that held
  # this named the session's kind. Removing a run or an entry checks its foreign
  # key by the id alone, which those indexes cannot answer, so every one
  # retention removed read the whole sessions table (2026-10-04 review). An
  # owner's id is set only on its own kind of session
  # (`episode_work_session_owner_valid`), so the same uniqueness holds over the
  # rows that carry one, and the check can use that.

  @owners [
    {:episode_work_sessions_learning_run_id_index, [:learning_run_id], "learning"},
    {:episode_work_sessions_improvement_run_id_index, [:improvement_run_id], "improvement"},
    {:episode_work_sessions_knowledge_run_id_index, [:knowledge_run_id], "knowledge"},
    {:episode_work_sessions_admission_generation_index, [:admission_input_id, :generation],
     "admission"}
  ]

  def up do
    for {name, [owner | _rest] = columns, _kind} <- @owners do
      drop(index(:episode_work_sessions, columns, name: name))

      create(
        unique_index(:episode_work_sessions, columns, name: name, where: "#{owner} IS NOT NULL")
      )
    end
  end

  def down do
    for {name, [owner | _rest] = columns, kind} <- @owners do
      drop(index(:episode_work_sessions, columns, name: name))
      where = "execution_kind = '#{kind}'"

      where =
        if owner == :admission_input_id,
          do: where <> " AND admission_input_id IS NOT NULL",
          else: where

      create(unique_index(:episode_work_sessions, columns, name: name, where: where))
    end
  end
end
