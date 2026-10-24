defmodule Ryker.Repo.Migrations.ExplicitCompletionRetriesKeepTheirAttemptBudget do
  use Ecto.Migration

  def up do
    alter table(:episode_work_turns) do
      add(:completion_retry_base_count, :bigint, null: false, default: 0)
    end

    create(
      constraint(:episode_work_turns, :episode_work_turn_completion_retry_base_count_valid,
        check:
          "completion_retry_base_count >= 0 AND completion_retry_base_count <= work_attempt_count"
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{table()} WHERE completion_retry_base_count > 0) THEN
        RAISE EXCEPTION 'completion retry budgets exist; rollback would strand retained results';
      END IF;
    END $$;
    """)

    drop(constraint(:episode_work_turns, :episode_work_turn_completion_retry_base_count_valid))

    alter table(:episode_work_turns) do
      remove(:completion_retry_base_count)
    end
  end

  defp table,
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".episode_work_turns)
end
