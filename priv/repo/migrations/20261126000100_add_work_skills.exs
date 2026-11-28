defmodule Ryker.Repo.Migrations.AddWorkSkills do
  use Ecto.Migration

  def change do
    for table_name <- [:work_settings, :environment_settings] do
      alter table(table_name) do
        add(:enabled_skills, {:array, :text}, null: false, default: [])
      end
    end
  end
end
