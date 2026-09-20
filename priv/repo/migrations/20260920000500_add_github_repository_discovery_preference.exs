defmodule Ryker.Repo.Migrations.AddGitHubRepositoryDiscoveryPreference do
  use Ecto.Migration

  def change do
    alter table(:github_settings) do
      add(:auto_add_repositories, :boolean, null: false, default: false)
    end
  end
end
