defmodule Responder.Repo.Migrations.RecordAdmissionAttempts do
  use Ecto.Migration

  def up do
    create table(:admission_attempts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:input_id, references(:ingress_inbox_entries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:generation, :integer, null: false)
      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:submission, :text)
      add(:submission_fingerprint, :text)
      add(:session_ref, :text)
      add(:turn_ref, :text)
      add(:execution_target, :text)
      add(:phase, :text, null: false, default: "context_prepared")
      add(:milestones, :text, null: false, default: "{}")
      add(:measurements, :text, null: false, default: "{}")
      add(:response, :text)
      add(:operational_pruned_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:admission_attempts, [:input_id, :generation]))
    create(index(:admission_attempts, [:inserted_at, :id]))

    create(
      constraint(:admission_attempts, :admission_attempt_identity_valid,
        check:
          "generation > 0 AND octet_length(policy) BETWEEN 1 AND 1024 AND policy_digest ~ '^[0-9a-f]{64}$'"
      )
    )

    create(
      constraint(:admission_attempts, :admission_attempt_submission_valid,
        check:
          "(submission IS NULL AND submission_fingerprint IS NULL) OR (submission IS NOT NULL AND submission_fingerprint ~ '^[0-9a-f]{64}$')"
      )
    )

    execute("""
    CREATE TRIGGER responder_control_plane_changed AFTER INSERT OR UPDATE OR DELETE
      ON #{relation()} FOR EACH STATEMENT EXECUTE FUNCTION #{schema()}.responder_control_plane_notify()
    """)
  end

  def down do
    # Do not silently discard request evidence in an operator rollback.
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM #{relation()} LIMIT 1) THEN RAISE EXCEPTION 'admission attempt history must be exported before rollback'; END IF; END $$"
    )

    drop(table(:admission_attempts))
  end

  defp relation, do: "#{schema()}.admission_attempts"
  defp schema, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end
