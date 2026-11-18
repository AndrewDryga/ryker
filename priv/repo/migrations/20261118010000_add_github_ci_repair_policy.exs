defmodule Ryker.Repo.Migrations.AddGitHubCIRepairPolicy do
  use Ecto.Migration

  def up do
    # Existing installations already repair Ryker's PRs. New repositories must opt in.
    alter table(:repository_settings) do
      add(:github_ci_repair, :text, null: false, default: "own")
    end

    execute("ALTER TABLE repository_settings ALTER COLUMN github_ci_repair SET DEFAULT 'off'")

    create(
      constraint(:repository_settings, :repository_ci_repair_valid,
        check: "github_ci_repair IN ('off', 'own', 'all')"
      )
    )
  end

  def down do
    raise "Restore the controller backup to undo CI policy without discarding operator choices"
  end
end
