defmodule Ryker.Repo.Migrations.RecordDetectedSlackNames do
  use Ecto.Migration

  def change do
    alter table(:slack_settings) do
      add(:workspace_name, :string)
      add(:bot_name, :string)
    end

    create(
      constraint(:slack_settings, :slack_settings_workspace_name_length,
        check: "workspace_name IS NULL OR char_length(workspace_name) BETWEEN 1 AND 256"
      )
    )

    create(
      constraint(:slack_settings, :slack_settings_bot_name_length,
        check: "bot_name IS NULL OR char_length(bot_name) BETWEEN 1 AND 256"
      )
    )
  end
end
