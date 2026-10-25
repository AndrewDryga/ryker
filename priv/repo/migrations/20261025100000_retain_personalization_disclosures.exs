defmodule Ryker.Repo.Migrations.RetainPersonalizationDisclosures do
  use Ecto.Migration

  def change do
    alter table(:episode_work_sessions) do
      # Old native transcripts have unknown custody, never an invented empty history.
      add(:personalization_exposures, :text)
    end
  end
end
