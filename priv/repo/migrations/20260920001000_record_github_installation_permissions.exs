defmodule Ryker.Repo.Migrations.RecordGitHubInstallationPermissions do
  use Ecto.Migration

  def change do
    alter table(:github_binding_settings) do
      add(:granted_permissions, :jsonb, null: false, default: fragment("'{}'::jsonb"))
    end

    create(
      constraint(:github_binding_settings, :github_binding_permissions_valid,
        check: "jsonb_typeof(granted_permissions) = 'object'"
      )
    )
  end
end
