defmodule Ryker.Repo.Migrations.KeepWhenTheReportWasSaved do
  use Ecto.Migration

  # The weekly report never posts a send time that passed before its settings
  # were last saved, and it read that save from the settings audit, which the
  # audit horizon prunes. With a short horizon, a report turned on after its
  # send time posted that stale week once the save was pruned (2026-10-04
  # review). The report keeps the time itself; an existing report starts from
  # its newest save still on record.
  def up do
    alter table(:report_settings) do
      add(:saved_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE report_settings
    SET saved_at = (SELECT max(inserted_at) FROM settings_edits WHERE domain = 'report')
    """)
  end

  def down do
    alter table(:report_settings) do
      remove(:saved_at)
    end
  end
end
