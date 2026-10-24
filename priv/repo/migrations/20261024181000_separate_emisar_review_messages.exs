defmodule Ryker.Repo.Migrations.SeparateEmisarReviewMessages do
  use Ecto.Migration

  def up do
    create table(:emisar_approval_messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:turn_id, references(:episode_work_turns, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:connection_ref, :text, null: false)
      add(:ref, :text, null: false)
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:thread_ref, :text)
      add(:external_receipt, :text)
      add(:card_fingerprint, :text)
      add(:checked_at, :utc_datetime_usec)
      add(:generation, :bigint, null: false, default: 1)
      add(:status, :text, null: false, default: "active")
      add(:attempt_count, :bigint, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:lease_ref, :binary_id)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      add(:last_error_detail, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:emisar_approval_messages, [:turn_id]))
    create(unique_index(:emisar_approval_messages, [:ref]))
    create(index(:emisar_approval_messages, [:connection_ref, :status, :checked_at]))

    create(
      constraint(:emisar_approval_messages, :emisar_approval_message_valid,
        check: """
        transport = 'slack' AND char_length(connection_ref) BETWEEN 1 AND 64
        AND char_length(ref) BETWEEN 1 AND 256 AND char_length(conversation_ref) BETWEEN 1 AND 1024
        AND (thread_ref IS NULL OR char_length(thread_ref) BETWEEN 1 AND 1024)
        AND generation > 0 AND attempt_count >= 0 AND status IN ('active', 'blocked')
        AND (card_fingerprint IS NULL OR card_fingerprint ~ '^[0-9a-f]{64}$')
        AND ((lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
          OR (lease_ref IS NOT NULL AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL))
        """
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{table()}) THEN
        RAISE EXCEPTION 'approval messages exist; rollback would strand retained deliveries';
      END IF;
    END $$;
    """)

    drop(table(:emisar_approval_messages))
  end

  defp table,
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".emisar_approval_messages)
end
