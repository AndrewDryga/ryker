defmodule Ryker.Repo.Migrations.ExplicitCompletionRetriesCaptureANewSnapshot do
  use Ecto.Migration

  def up do
    alter table(:episode_work_turns) do
      add(:checkpoint_retry_generation, :bigint, null: false, default: 0)
    end

    create(
      constraint(:episode_work_turns, :episode_work_turn_checkpoint_retry_generation_valid,
        check: "checkpoint_retry_generation >= 0"
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{table()} WHERE checkpoint_retry_generation > 0) THEN
        RAISE EXCEPTION 'checkpoint retries exist; rollback would strand retained operations';
      END IF;
    END $$;
    """)

    drop(constraint(:episode_work_turns, :episode_work_turn_checkpoint_retry_generation_valid))

    alter table(:episode_work_turns) do
      remove(:checkpoint_retry_generation)
    end
  end

  defp table,
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".episode_work_turns)
end
