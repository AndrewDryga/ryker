defmodule Ryker.Repo.Migrations.MarkWithdrawnGithubRequests do
  use Ecto.Migration

  def change do
    alter table(:ingress_inbox_entries) do
      add(:github_withdrawn_at, :utc_datetime_usec)
    end
  end
end
