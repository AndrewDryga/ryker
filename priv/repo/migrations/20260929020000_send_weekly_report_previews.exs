defmodule Ryker.Repo.Migrations.SendWeeklyReportPreviews do
  use Ecto.Migration

  # V17, Andrew, 2026-09-28: "why not to send real report to configured
  # channel as a preview?" Settings › Weekly report can now send the report
  # to its channel at once. A preview travels the week's report custody
  # (`Ryker.WeeklyReport.Custody`) so a refusal shows on Failures and a retry
  # never posts twice, but it is not the week's report: `preview` rows are
  # left out of the one-report-per-week index, so the scheduled report still
  # posts after a preview, and any number of previews can be sent.
  #
  # Rolling back refuses while a preview is on record: the previous release
  # would read one as the week's report and skip that week. Delete the
  # previews first (they are posted or failed sends; what was posted stays in
  # Slack).

  def up do
    alter table(:weekly_reports) do
      add(:preview, :boolean, null: false, default: false)
    end

    drop(unique_index(:weekly_reports, [:week]))
    create(unique_index(:weekly_reports, [:week], where: "NOT preview"))
  end

  def down do
    table = if prefix(), do: "#{prefix()}.weekly_reports", else: "weekly_reports"

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{table} WHERE preview) THEN
        RAISE EXCEPTION 'weekly report previews are on record; delete them before rolling back';
      END IF;
    END $$;
    """)

    drop(unique_index(:weekly_reports, [:week]))
    create(unique_index(:weekly_reports, [:week]))

    alter table(:weekly_reports) do
      remove(:preview)
    end
  end
end
