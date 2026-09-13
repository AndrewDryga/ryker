defmodule Ryker.Repo.Migrations.RecordMemoryMaintenanceFailures do
  use Ecto.Migration

  def change do
    alter table(:episode_work_turns) do
      add(:summary_error_code, :text)
    end

    alter table(:conversation_summaries) do
      add(:compaction_error_code, :text)
      add(:compaction_retry_at, :utc_datetime_usec)
    end

    create(index(:conversation_summaries, [:compaction_retry_at, :updated_at]))
  end
end
