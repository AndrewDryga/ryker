defmodule Responder.Repo.Migrations.CreateModelInstructions do
  use Ecto.Migration

  def change do
    create table(:model_instruction_settings, primary_key: false) do
      add(:scope_ref, :text, primary_key: true)
      add(:text, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:saved_by, :text, null: false)
      add(:saved_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:model_instruction_settings, :model_instruction_setting_valid,
        check:
          "(scope_ref = 'global' OR scope_ref ~ '^slack:[A-Z0-9]+:[A-Z0-9]+$') " <>
            "AND octet_length(scope_ref) <= 519 " <>
            "AND octet_length(text) <= 8192 AND revision > 0 " <>
            "AND char_length(saved_by) BETWEEN 1 AND 256"
      )
    )

    create table(:model_instruction_edits, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:scope_ref, references(:model_instruction_settings, column: :scope_ref, type: :text),
        null: false
      )

      add(:revision, :bigint, null: false)
      add(:actor_ref, :text, null: false)
      add(:text_fingerprint, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:model_instruction_edits, [:scope_ref, :revision]))

    create(
      constraint(:model_instruction_edits, :model_instruction_edit_valid,
        check:
          "revision > 0 AND char_length(actor_ref) BETWEEN 1 AND 256 " <>
            "AND text_fingerprint ~ '^[0-9a-f]{64}$'"
      )
    )
  end
end
