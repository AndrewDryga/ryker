defmodule Ryker.Repo.Migrations.RecordConfigurationImports do
  use Ecto.Migration

  # The one-time configuration importer records what it applied, never what it
  # read: a fingerprint of the exact source bytes, a fingerprint of the semantic
  # plan, the settings revision the import produced, the actor and the time. No
  # value from the retired document is stored here, so the receipt is safe to
  # read and export. An identical rerun matches a receipt and reports already
  # applied; a changed source, or a settings revision that moved because someone
  # edited the installation afterwards, is a conflict rather than an overwrite of
  # that later work.
  @hex64 "^[0-9a-f]{64}$"

  def up do
    create table(:settings_import_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:source_fingerprint, :text, null: false)
      add(:plan_fingerprint, :text, null: false)
      add(:host_ref, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:actor_ref, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:settings_import_receipts, [:source_fingerprint]))

    create(
      constraint(:settings_import_receipts, :settings_import_receipt_valid,
        check:
          "source_fingerprint ~ '#{@hex64}' AND plan_fingerprint ~ '#{@hex64}' " <>
            "AND char_length(host_ref) BETWEEN 1 AND 128 AND revision > 0 " <>
            "AND char_length(actor_ref) BETWEEN 1 AND 256"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("settings_import_receipts")} LIMIT 1) THEN
        RAISE EXCEPTION 'configuration import receipts have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(table(:settings_import_receipts))
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
