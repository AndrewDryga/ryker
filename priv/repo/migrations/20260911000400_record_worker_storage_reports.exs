defmodule Ryker.Repo.Migrations.RecordWorkerStorageReports do
  use Ecto.Migration

  def up do
    alter table(:coop_workers) do
      # NULL is the only honest value for a worker that reported no measurement.
      add(:storage, :text)
      add(:storage_reclaimed_bytes, :bigint, null: false, default: 0)
    end

    create(
      constraint(:coop_workers, :coop_worker_storage_valid,
        check:
          "storage_reclaimed_bytes >= 0 AND (" <>
            "storage IS NULL OR (" <>
            "octet_length(storage) <= 4096" <>
            " AND jsonb_typeof(storage::jsonb) = 'object'" <>
            " AND (storage::jsonb ->> 'version')::int = 1" <>
            " AND storage::jsonb ->> 'allocation' IN ('open', 'refused')" <>
            " AND (storage::jsonb ->> 'disposable_bytes')::bigint >= 0" <>
            " AND (storage::jsonb ->> 'protected_bytes')::bigint >= 0" <>
            "))"
      )
    )
  end

  def down do
    drop(constraint(:coop_workers, :coop_worker_storage_valid))

    alter table(:coop_workers) do
      remove(:storage_reclaimed_bytes)
      remove(:storage)
    end
  end
end
