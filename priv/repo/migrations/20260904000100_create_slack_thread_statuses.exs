defmodule Responder.Repo.Migrations.CreateSlackThreadStatuses do
  use Ecto.Migration

  def change do
    create table(:slack_thread_statuses, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_ref, :text, null: false)
      add(:channel_ref, :text, null: false)
      add(:thread_ref, :text, null: false)
      add(:phase, :text, null: false)
      add(:desired_text, :text, null: false)
      add(:generation, :bigint, null: false, default: 1)
      add(:delivered_generation, :bigint, null: false, default: 0)
      add(:status, :text, null: false, default: "pending")
      add(:attempt_count, :bigint, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:lease_owner, :text)
      add(:lease_ref, :uuid)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      add(:last_error_detail, :text)
      add(:delivered_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:slack_thread_statuses, [:workspace_ref, :channel_ref, :thread_ref],
        name: :slack_thread_status_identity_unique
      )
    )

    create(
      index(:slack_thread_statuses, [:workspace_ref, :status, :next_attempt_at, :updated_at],
        name: :slack_thread_status_due_index
      )
    )

    create(
      constraint(:slack_thread_statuses, :slack_thread_status_valid,
        check: """
        char_length(workspace_ref) BETWEEN 1 AND 256
        AND char_length(channel_ref) BETWEEN 1 AND 256
        AND thread_ref ~ '^[0-9]{10,}\\.[0-9]{1,6}$'
        AND phase IN ('queued', 'admitting', 'admission_retry', 'working', 'delivery',
                      'waiting_for_input', 'waiting_for_event', 'blocked', 'clear')
        AND octet_length(desired_text) <= 100
        AND generation >= 1
        AND delivered_generation BETWEEN 0 AND generation
        AND attempt_count >= 0
        AND status IN ('pending', 'delivered')
        AND ((status = 'pending' AND delivered_generation < generation)
             OR (status = 'delivered' AND delivered_generation = generation))
        AND ((lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
             OR (status = 'pending' AND lease_ref IS NOT NULL
                 AND char_length(lease_owner) BETWEEN 1 AND 1024
                 AND lease_expires_at IS NOT NULL))
        AND ((last_error_code IS NULL AND last_error_detail IS NULL)
             OR (status = 'pending' AND char_length(last_error_code) BETWEEN 1 AND 128
                 AND octet_length(last_error_detail) BETWEEN 1 AND 4096))
        AND (status <> 'delivered'
             OR (delivered_at IS NOT NULL AND next_attempt_at IS NULL
                 AND lease_ref IS NULL AND last_error_code IS NULL))
        """
      )
    )
  end
end
