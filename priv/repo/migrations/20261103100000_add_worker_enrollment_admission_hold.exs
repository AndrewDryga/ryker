defmodule Ryker.Repo.Migrations.AddWorkerEnrollmentAdmissionHold do
  use Ecto.Migration

  def change do
    alter table(:coop_worker_enrollment_tokens) do
      add(:stop_admission, :boolean, null: false, default: false)
    end
  end
end
