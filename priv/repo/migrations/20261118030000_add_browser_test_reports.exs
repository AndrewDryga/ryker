defmodule Ryker.Repo.Migrations.AddBrowserTestReports do
  use Ecto.Migration

  def up do
    create table(:browser_test_reports, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:turn_id, references(:episode_work_turns, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:fingerprint, :text, null: false)
      add(:source, :text, null: false)
      add(:document, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:browser_test_reports, [:turn_id, :fingerprint]))

    create(
      constraint(:browser_test_reports, :browser_test_report_valid,
        check: """
        fingerprint ~ '^[0-9a-f]{64}$'
        AND octet_length(source) <= 4096 AND jsonb_typeof(source::jsonb) = 'object'
        AND octet_length(document) <= 32768 AND jsonb_typeof(document::jsonb) = 'object'
        """
      )
    )
  end

  def down do
    raise "Restore the controller backup to undo browser reports without deleting evidence"
  end
end
