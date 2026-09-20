defmodule Ryker.Repo.Migrations.TrackGitHubEventDuplicates do
  use Ecto.Migration

  def change do
    alter table(:github_repository_events) do
      add(:duplicate_count, :integer, null: false, default: 0)
      add(:last_duplicate_at, :utc_datetime_usec)
    end

    create(
      constraint(:github_repository_events, :github_repository_duplicate_count_valid,
        check: "duplicate_count >= 0"
      )
    )
  end
end
