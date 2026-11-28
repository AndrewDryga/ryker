defmodule Ryker.Repo.Migrations.AddModelInferencePermits do
  use Ecto.Migration

  def change do
    create table(:coop_model_buckets, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:concurrency, :integer, null: false, default: 1)
      add(:blocked_until, :utc_datetime_usec)
      add(:updated_by, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:coop_model_buckets, :coop_model_bucket_valid,
        check:
          "id ~ '^[0-9a-f]{64}$' AND concurrency BETWEEN 0 AND 256 AND octet_length(updated_by) BETWEEN 1 AND 256"
      )
    )

    create table(:coop_model_permits, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      # Retention of a model run must not silently release an active permit.
      add(:run_id, references(:coop_model_runs, type: :uuid, on_delete: :nilify_all))

      add(:bucket_id, references(:coop_model_buckets, type: :text, on_delete: :restrict),
        null: false
      )

      add(:job_ref, :text, null: false)
      add(:provider, :text, null: false)
      add(:account, :text, null: false)
      add(:account_epoch, :bigint, null: false)
      add(:owner_boot, :uuid, null: false)
      add(:owner_pid, :text, null: false)
      add(:lease_pid, :text)
      add(:upstream_pid, :text)
      add(:kind, :text, null: false)
      add(:response_id, :text)
      add(:state, :text, null: false)
      add(:deadline, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
      add(:finish_reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:coop_model_permits, [:bucket_id], where: "state <> 'released'"))
    create(index(:coop_model_permits, [:finished_at]))

    create(
      constraint(:coop_model_permits, :coop_model_permit_valid,
        check:
          "kind IN ('http','websocket') AND state IN ('reserved','active','released','uncertain') AND provider IN ('claude','codex') AND account_epoch > 0 AND octet_length(job_ref) BETWEEN 1 AND 256 AND octet_length(account) BETWEEN 1 AND 128 AND octet_length(owner_pid) BETWEEN 1 AND 128 AND ((state = 'released' AND finished_at IS NOT NULL AND finish_reason IS NOT NULL) OR (state <> 'released' AND finished_at IS NULL))"
      )
    )
  end
end
