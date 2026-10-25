defmodule Ryker.Repo.Migrations.RetainGuidanceDisclosures do
  use Ecto.Migration

  def change do
    alter table(:episode_work_sessions) do
      # NULL is unproven historical custody. Only a new Session can start empty.
      add(:guidance_exposures, :text)
    end
  end
end
