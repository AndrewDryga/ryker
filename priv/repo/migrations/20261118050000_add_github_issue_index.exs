defmodule Ryker.Repo.Migrations.AddGitHubIssueIndex do
  use Ecto.Migration

  def up do
    create table(:github_issue_indexes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:identity, :text, null: false)
      add(:binding_ref, :text, null: false)
      add(:repository_ref, :text, null: false)
      add(:repository_id, :bigint, null: false)
      add(:installation_id, :bigint, null: false)
      add(:page, :integer, null: false, default: 1)
      add(:backfill_complete, :boolean, null: false, default: false)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:lease_ref, :uuid)
      add(:lease_expires_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:github_issue_indexes, [:identity]))
    create(index(:github_issue_indexes, [:next_attempt_at]))

    create(
      constraint(:github_issue_indexes, :github_issue_index_valid,
        check: "repository_id > 0 AND installation_id > 0 AND page BETWEEN 1 AND 6"
      )
    )

    create table(:github_indexed_issues, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:index_id, references(:github_issue_indexes, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:number, :integer, null: false)
      add(:generation, :integer, null: false, default: 1)
      add(:pending, :boolean, null: false, default: true)
      add(:triage_pending, :boolean, null: false, default: false)
      add(:document, :text)
      add(:embedding, {:array, :real})
      add(:embedding_model, :text)
      add(:last_triaged_digest, :text)
      add(:next_attempt_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:github_indexed_issues, [:index_id, :number]))
    create(index(:github_indexed_issues, [:index_id, :pending, :next_attempt_at]))

    create(
      constraint(:github_indexed_issues, :github_indexed_issue_valid,
        check:
          "number > 0 AND generation > 0 AND (document IS NULL OR octet_length(document::text) <= 131072) AND (embedding IS NULL OR cardinality(embedding) BETWEEN 1 AND 4096)"
      )
    )
  end

  def down do
    raise "Restore the controller backup to undo issue indexing without losing triage receipts"
  end
end
