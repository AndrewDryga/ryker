defmodule Ryker.Repo.Migrations.SupersedeUnsentRoutingResponses do
  use Ecto.Migration

  def up do
    alter table(:delivery_routing_responses) do
      add(:first_write_started_at, :utc_datetime_usec)
      add(:superseding_revision, :bigint)
    end

    execute("""
    UPDATE delivery_routing_responses SET first_write_started_at = updated_at
    WHERE transport = 'slack' AND status IN ('pending', 'blocked')
      AND (attempt_count > 0 OR retry_generation > 0)
    """)

    drop(constraint(:delivery_routing_responses, :delivery_routing_response_custody_valid))

    create(
      constraint(:delivery_routing_responses, :delivery_routing_response_custody_valid,
        check: """
        status IN ('pending', 'blocked', 'delivered', 'superseded')
        AND ((lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
          OR (status = 'pending' AND length(lease_ref) > 0 AND length(lease_owner) > 0 AND lease_expires_at IS NOT NULL))
        AND (status = 'pending' OR next_attempt_at IS NULL)
        AND (status <> 'blocked' OR (length(last_error_code) > 0 AND length(last_error_detail) > 0))
        AND ((status = 'delivered' AND external_receipt IS NOT NULL AND length(external_receipt_fingerprint) = 64 AND delivered_at IS NOT NULL)
          OR (status <> 'delivered' AND external_receipt IS NULL AND external_receipt_fingerprint IS NULL AND delivered_at IS NULL))
        AND ((status = 'superseded' AND superseding_revision IS NOT NULL AND first_write_started_at IS NULL)
          OR (status <> 'superseded' AND superseding_revision IS NULL))
        """
      )
    )
  end
end
