defmodule Responder.Repo.Migrations.RecordTheSlackWorkspaceUrl do
  use Ecto.Migration

  # A Slack message link is `<workspace>/archives/<channel>/p<ts>`, and the host
  # knew every part of it except the workspace. So a card that wanted to point
  # at the exact question or the message it posted could only describe it, and
  # the reader had to go and find it. One optional setting, and the pointer
  # becomes a link; without it the card says nothing rather than linking
  # nowhere.
  def up do
    alter table(:slack_settings) do
      add(:workspace_url, :text)
    end

    create(
      constraint(:slack_settings, :slack_settings_workspace_url_valid,
        check:
          "workspace_url IS NULL OR " <>
            "(workspace_url ~ '^https://[a-z0-9-]{1,64}\\.slack\\.com/?$' " <>
            "AND char_length(workspace_url) <= 256)"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("slack_settings")} WHERE workspace_url IS NOT NULL LIMIT 1
      ) THEN
        RAISE EXCEPTION 'a recorded Slack workspace URL cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:slack_settings, :slack_settings_workspace_url_valid))

    alter table(:slack_settings) do
      remove(:workspace_url)
    end
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
