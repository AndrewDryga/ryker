defmodule Ryker.Repo.Migrations.EnableLearningByDefault do
  use Ecto.Migration

  def up do
    alter table(:learning_settings) do
      modify(:enabled, :boolean, null: false, default: true)
    end

    execute("""
    UPDATE learning_settings
    SET enabled = TRUE
    WHERE enabled = FALSE
      AND NOT EXISTS (
        SELECT 1
        FROM settings_edits
        WHERE domain = 'learning'
      )
    """)
  end

  def down do
    alter table(:learning_settings) do
      modify(:enabled, :boolean, null: false, default: false)
    end
  end
end
