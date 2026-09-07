defmodule Responder.Repo.Migrations.RecordWaitSchedulingErrors do
  use Ecto.Migration

  def up do
    alter table(:episode_state_records) do
      add(:wait_error, :string, size: 32)
    end

    create(
      constraint(:episode_state_records, :episode_state_record_wait_error_valid,
        check:
          "wait_error IS NULL OR (kind = 'event_wait' AND wait_error IN ('deadline', 'poll_after', 'timer_deadline', 'source_kind', 'cursor'))"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_state_records")} WHERE wait_error IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'wait scheduling diagnostics cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_state_records, :episode_state_record_wait_error_valid))

    alter table(:episode_state_records) do
      remove(:wait_error)
    end
  end

  defp qualified(table) do
    escaped = String.replace(prefix() || "public", "\"", "\"\"")
    "\"#{escaped}\".\"#{table}\""
  end
end
