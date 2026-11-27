defmodule Ryker.Repo.Migrations.AddFleetJobResources do
  use Ecto.Migration

  def change do
    alter table(:operator_fleet_jobs) do
      add(:resources, :map)
    end
  end
end
