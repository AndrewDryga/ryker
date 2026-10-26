defmodule Ryker.Repo.Migrations.AddFlywheel do
  use Ecto.Migration

  def change do
    create table(:flywheel_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:request_ref, :text, null: false)
      add(:mode, :text, null: false)
      add(:status, :text, null: false, default: "running")
      add(:starts_at, :utc_datetime_usec, null: false)
      add(:ends_at, :utc_datetime_usec, null: false)
      add(:progress, :map, null: false, default: %{})
      add(:policy, :map, null: false, default: %{})
      add(:lease_ref, :uuid, null: false)
      add(:lease_expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:flywheel_runs, [:request_ref]))
    create(unique_index(:flywheel_runs, [:status], where: "status = 'running'"))

    create(
      constraint(:flywheel_runs, :flywheel_run_valid,
        check:
          "mode IN ('suggest', 'auto') AND status IN ('running', 'complete', 'partial') AND starts_at < ends_at"
      )
    )

    create table(:flywheel_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:source, :text, null: false)
      add(:ref, :text, null: false)
      add(:version, :text, null: false)
      add(:run_id, references(:flywheel_runs, type: :uuid, on_delete: :delete_all), null: false)
      add(:reviewed_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:flywheel_receipts, [:source, :ref, :version]))
    create(index(:flywheel_receipts, [:run_id]))

    create table(:flywheel_findings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:key, :text, null: false)
      add(:run_id, references(:flywheel_runs, type: :uuid), null: false)
      add(:status, :text, null: false, default: "proposed")
      add(:owner, :text, null: false)
      add(:kind, :text, null: false)
      add(:proposal, :map, null: false)
      add(:evidence, {:array, :map}, null: false, default: [])
      add(:history, {:array, :map}, null: false, default: [])
      add(:task_id, :text)
      add(:revisit_at, :utc_datetime_usec)
      add(:deployed_version, :text)
      add(:shipped_at, :utc_datetime_usec)
      add(:outcome, :map)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:flywheel_findings, [:key]))
    create(unique_index(:flywheel_findings, [:task_id]))
    create(index(:flywheel_findings, [:run_id]))

    create(
      constraint(:flywheel_findings, :flywheel_finding_valid,
        check: """
        owner IN ('ryker', 'user', 'both')
        AND kind IN ('code', 'prompt', 'settings', 'tools', 'user_action', 'investigation')
        AND status IN ('proposed', 'ready', 'waiting_user', 'in_progress', 'shipped', 'verified', 'regressed', 'deferred', 'dismissed')
        """
      )
    )
  end
end
