defmodule Ryker.Repo.Migrations.AddOperatorFleetJobs do
  use Ecto.Migration

  def change do
    create table(:operator_fleet_jobs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:episode_id, references(:episode_kernel_episodes, type: :uuid, on_delete: :nilify_all))
      add(:request_digest, :text, null: false)
      add(:environment_ref, :text, null: false)
      add(:repository_ref, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:operator_fleet_jobs, [:episode_id]))
  end
end
