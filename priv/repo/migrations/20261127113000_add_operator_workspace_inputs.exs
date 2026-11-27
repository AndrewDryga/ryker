defmodule Ryker.Repo.Migrations.AddOperatorWorkspaceInputs do
  use Ecto.Migration

  def change do
    alter table(:operator_fleet_jobs) do
      add(:workspace_input_id, :uuid)
      add(:workspace_input, :map)
    end

    create(
      unique_index(:operator_fleet_jobs, [:workspace_input_id],
        where: "workspace_input_id IS NOT NULL"
      )
    )

    create(
      constraint(:operator_fleet_jobs, :workspace_input_pair,
        check: "(workspace_input IS NULL) = (workspace_input_id IS NULL)"
      )
    )
  end
end
