defmodule Ryker.Repo.Migrations.DistinguishInputSourceExposures do
  use Ecto.Migration

  def change do
    alter table(:episode_work_source_exposures) do
      # Older custody cannot prove a source was never recalled as memory.
      add(:input_only, :boolean, null: false, default: false)
    end
  end
end
