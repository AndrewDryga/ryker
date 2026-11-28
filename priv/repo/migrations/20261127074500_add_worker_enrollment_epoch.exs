defmodule Ryker.Repo.Migrations.AddWorkerEnrollmentEpoch do
  use Ecto.Migration

  def change do
    alter table(:coop_workers) do
      add(:enrollment_epoch, :uuid, null: false, default: fragment("gen_random_uuid()"))
    end
  end
end
