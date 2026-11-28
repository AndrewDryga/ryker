defmodule Ryker.Repo.Migrations.PinWorkerMachineCapacity do
  use Ecto.Migration

  def change do
    alter table(:coop_workers) do
      add(:machine_daemon, :text)
      add(:machine_report_required, :boolean, null: false, default: false)
    end

    # Revocation does not prove the old daemon's containers have stopped.
    create(unique_index(:coop_workers, [:machine_daemon]))

    create(
      constraint(:coop_workers, :coop_worker_machine_valid,
        check: "machine_daemon IS NULL OR machine_daemon ~ '^[0-9a-f]{64}$'"
      )
    )
  end
end
