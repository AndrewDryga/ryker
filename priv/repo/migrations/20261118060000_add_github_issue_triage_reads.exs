defmodule Ryker.Repo.Migrations.AddGitHubIssueTriageReads do
  use Ecto.Migration

  def up do
    create table(:github_issue_triage_reads, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:request_id, references(:github_issue_requests, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:number, :integer, null: false)
      add(:fingerprint, :text, null: false)
      add(:document, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:github_issue_triage_reads, [:request_id, :fingerprint]))

    create(
      constraint(:github_issue_triage_reads, :github_issue_triage_read_valid,
        check:
          "number > 0 AND fingerprint ~ '^[0-9a-f]{64}$' AND octet_length(document) <= 131072 AND jsonb_typeof(document::jsonb) = 'object'"
      )
    )
  end

  def down do
    raise "Restore the controller backup to preserve inspected issue evidence"
  end
end
