defmodule Ryker.Repo.Migrations.TrackGitHubRepositoryMaterialization do
  use Ecto.Migration

  def change do
    alter table(:repository_settings) do
      add(:materialized_at, :utc_datetime_usec)
    end

    create(
      index(:repository_settings, [:github_access, :last_github_event_at, :materialized_at],
        name: :repository_settings_materialization_due_index
      )
    )
  end
end
