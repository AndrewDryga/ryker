defmodule Ryker.Repo.Migrations.HoldStaleSlackActions do
  use Ecto.Migration

  def up do
    alter table(:platform_actions) do
      add(:authorization_order, :bigint, null: false, default: 0)
      add(:thread_receipt, :text)
      add(:first_write_started_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE platform_actions SET authorization_order = split_part(host_slot, ':', 2)::bigint
    WHERE tool IN ('set_slack_reaction', 'post_slack_update') AND host_slot ~ '^(reaction|update):[1-3]$'
    """)

    execute("""
    UPDATE platform_actions a SET thread_receipt = t.thread_receipt,
      first_write_started_at = CASE WHEN a.attempt_count > 0 OR a.retry_generation > 0 THEN a.updated_at END
    FROM episode_work_turns t WHERE a.turn_id = t.id AND a.transport = 'slack'
      AND a.tool IN ('set_slack_reaction', 'post_slack_update') AND a.status IN ('pending', 'blocked')
    """)

    drop(constraint(:platform_actions, :platform_actions_custody_valid))

    create(
      constraint(:platform_actions, :platform_actions_custody_valid,
        check: """
        status IN ('pending','blocked','delivered','held','retired')
        AND ((lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
          OR (status = 'pending' AND lease_ref IS NOT NULL AND length(lease_owner) BETWEEN 1 AND 1024 AND lease_expires_at IS NOT NULL))
        AND (status = 'pending' OR next_attempt_at IS NULL)
        AND (status <> 'blocked' OR (length(last_error_code) BETWEEN 1 AND 128 AND length(last_error_detail) BETWEEN 1 AND 4096))
        AND ((status = 'delivered' AND external_receipt IS NOT NULL AND external_receipt_fingerprint IS NOT NULL AND length(external_receipt_fingerprint) = 64 AND delivered_at IS NOT NULL)
          OR (status <> 'delivered' AND external_receipt IS NULL AND external_receipt_fingerprint IS NULL AND delivered_at IS NULL))
        AND (status NOT IN ('held', 'retired') OR (first_write_started_at IS NULL AND thread_receipt IS NOT NULL))
        """
      )
    )
  end
end
