defmodule Ryker.Repo.Migrations.AddWorkerAdmissionControl do
  use Ecto.Migration

  def change do
    alter table(:coop_workers) do
      add(:admission_stopped_at, :utc_datetime_usec)
      add(:admission_stopped_by, :text)
    end

    create(
      constraint(:coop_workers, :coop_worker_admission_valid,
        check:
          "((admission_stopped_at IS NULL) = (admission_stopped_by IS NULL)) AND " <>
            "(admission_stopped_by IS NULL OR char_length(admission_stopped_by) BETWEEN 1 AND 256)"
      )
    )
  end
end
