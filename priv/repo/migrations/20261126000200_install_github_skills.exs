defmodule Ryker.Repo.Migrations.InstallGitHubSkills do
  use Ecto.Migration

  def change do
    alter table(:work_settings) do
      add(:installed_skills, :map, null: false, default: %{})
    end
  end
end
