defmodule Responder.Repo.Migrations.CreateCardLabPosts do
  use Ecto.Migration

  def change do
    create table(:card_lab_posts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_ref, :text, null: false)
      add(:channel_ref, :text, null: false)
      add(:channel_name, :text, null: false)
      add(:card_id, :text, null: false)
      add(:state_id, :text, null: false)
      add(:payload, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:request_fingerprint, :text, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:delivered_state_id, :text)
      add(:delivered_fingerprint, :text)
      add(:message_ref, :text)
      add(:status, :text, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:lease_ref, :uuid)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec, null: false)
      add(:last_error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:card_lab_posts, [:workspace_ref, :status, :next_attempt_at]))
    create(index(:card_lab_posts, [:card_id, :inserted_at]))

    create(
      constraint(:card_lab_posts, :card_lab_posts_valid,
        check: """
        status IN ('pending', 'posted', 'blocked') AND revision > 0 AND attempt_count >= 0 AND
        workspace_ref ~ '^T[A-Z0-9]+$' AND channel_ref ~ '^[CG][A-Z0-9]+$' AND
        octet_length(card_id) BETWEEN 1 AND 120 AND octet_length(state_id) BETWEEN 1 AND 120 AND
        fingerprint ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$' AND
        (message_ref IS NULL OR message_ref ~ '^[0-9]+[.][0-9]+$') AND
        ((lease_ref IS NULL) = (lease_expires_at IS NULL)) AND
        (status <> 'posted' OR (message_ref IS NOT NULL AND delivered_fingerprint = fingerprint))
        """
      )
    )

    execute("SELECT 1", """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("card_lab_posts")} LIMIT 1) THEN
        RAISE EXCEPTION 'card lab posts contain delivery custody and cannot be rolled back safely';
      END IF;
    END $$
    """)
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
