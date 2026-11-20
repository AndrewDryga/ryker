defmodule Ryker.Repo.Migrations.KeepSubmittedGitHubReviews do
  use Ecto.Migration

  def change do
    alter table(:episode_work_state_tool_calls) do
      add(:github_review, :map)
    end
  end
end
