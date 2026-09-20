defmodule Ryker.Repo.Migrations.AddGitHubActionGrants do
  use Ecto.Migration

  def change do
    alter table(:github_binding_settings) do
      add(:action_grants, {:array, :string},
        null: false,
        default: ["read", "review", "open_pull_request", "update_ryker_branch", "rerun_ci"]
      )
    end
  end
end
