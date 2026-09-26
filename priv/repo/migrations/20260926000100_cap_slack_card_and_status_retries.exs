defmodule Ryker.Repo.Migrations.CapSlackCardAndStatusRetries do
  use Ecto.Migration

  # A Slack task card or thread status Slack kept refusing was written again
  # for as long as its task existed (hourly for a card, every minute for a
  # status), edited a message Slack had already said was gone, and was listed
  # nowhere. Both now stop after their attempts, or at once when Slack says the
  # message or channel is gone, and hold `blocked` until a person retries them
  # from Failures. A blocked row is that person's only record of why, so a
  # rollback refuses while any exists.
  @thread_status_valid_before """
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

  @thread_status_valid_after """
  char_length(workspace_ref) BETWEEN 1 AND 256
  AND char_length(channel_ref) BETWEEN 1 AND 256
  AND thread_ref ~ '^[0-9]{10,}\\.[0-9]{1,6}$'
  AND phase IN ('queued', 'admitting', 'admission_retry', 'working', 'delivery',
                'waiting_for_input', 'waiting_for_event', 'blocked', 'clear')
  AND octet_length(desired_text) <= 100
  AND generation >= 1
  AND delivered_generation BETWEEN 0 AND generation
  AND attempt_count >= 0
  AND status IN ('pending', 'delivered', 'blocked')
  AND ((status IN ('pending', 'blocked') AND delivered_generation < generation)
       OR (status = 'delivered' AND delivered_generation = generation))
  AND ((lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
       OR (status = 'pending' AND lease_ref IS NOT NULL
           AND char_length(lease_owner) BETWEEN 1 AND 1024
           AND lease_expires_at IS NOT NULL))
  AND ((last_error_code IS NULL AND last_error_detail IS NULL)
       OR (status IN ('pending', 'blocked') AND char_length(last_error_code) BETWEEN 1 AND 128
           AND octet_length(last_error_detail) BETWEEN 1 AND 4096))
  AND (status <> 'delivered'
       OR (delivered_at IS NOT NULL AND next_attempt_at IS NULL
           AND lease_ref IS NULL AND last_error_code IS NULL))
  AND (status <> 'blocked'
       OR (last_error_code IS NOT NULL AND next_attempt_at IS NULL AND lease_ref IS NULL))
  """

  @task_card_status_valid """
  status IN ('active', 'blocked')
  AND (status <> 'blocked'
       OR (last_error_code IS NOT NULL AND next_attempt_at IS NULL AND lease_ref IS NULL))
  """

  def up do
    alter table(:slack_task_cards) do
      add(:status, :text, null: false, default: "active")
    end

    create(
      constraint(:slack_task_cards, :slack_task_card_status_valid, check: @task_card_status_valid)
    )

    drop(constraint(:slack_thread_statuses, :slack_thread_status_valid))

    create(
      constraint(:slack_thread_statuses, :slack_thread_status_valid,
        check: @thread_status_valid_after
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("slack_task_cards")} WHERE status = 'blocked' LIMIT 1)
         OR EXISTS (
           SELECT 1 FROM #{qualified("slack_thread_statuses")} WHERE status = 'blocked' LIMIT 1
         ) THEN
        RAISE EXCEPTION 'blocked Slack task cards or thread statuses have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:slack_thread_statuses, :slack_thread_status_valid))

    create(
      constraint(:slack_thread_statuses, :slack_thread_status_valid,
        check: @thread_status_valid_before
      )
    )

    drop(constraint(:slack_task_cards, :slack_task_card_status_valid))

    alter table(:slack_task_cards) do
      remove(:status)
    end
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
