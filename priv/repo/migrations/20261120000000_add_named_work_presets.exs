defmodule Ryker.Repo.Migrations.AddNamedWorkPresets do
  use Ecto.Migration

  def change do
    alter table(:work_settings) do
      add(:contributor_preset, :text)
      add(:code_review_preset, :text)
    end
  end
end
