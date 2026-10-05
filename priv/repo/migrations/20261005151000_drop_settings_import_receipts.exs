defmodule Ryker.Repo.Migrations.DropSettingsImportReceipts do
  use Ecto.Migration

  # Receipts of the retired one-time configuration import. Nothing has written
  # one since the import was removed, and the audit horizon has pruned the
  # last of them (2026-10-04 review: the live install held none).
  def up do
    drop(table(:settings_import_receipts))
  end

  def down do
    create table(:settings_import_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:source_fingerprint, :text, null: false)
      add(:plan_fingerprint, :text, null: false)
      add(:host_ref, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:actor_ref, :text, null: false)
      add(:inserted_at, :naive_datetime_usec, null: false)
    end

    create(unique_index(:settings_import_receipts, [:source_fingerprint]))

    create(
      constraint(:settings_import_receipts, :settings_import_receipt_valid,
        check: """
        source_fingerprint ~ '^[0-9a-f]{64}$' AND plan_fingerprint ~ '^[0-9a-f]{64}$' AND
        char_length(host_ref) BETWEEN 1 AND 128 AND revision > 0 AND
        char_length(actor_ref) BETWEEN 1 AND 256
        """
      )
    )
  end
end
