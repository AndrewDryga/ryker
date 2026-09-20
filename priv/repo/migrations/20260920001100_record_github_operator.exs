defmodule Ryker.Repo.Migrations.RecordGitHubOperator do
  use Ecto.Migration

  def change do
    alter table(:github_settings) do
      add(:bot_actor_id, :bigint)
      add(:bot_login, :text)
      add(:operator_actor_id, :bigint)
      add(:operator_login, :text)
    end

    create(
      constraint(:github_settings, :github_settings_bot_valid,
        check:
          "(bot_actor_id IS NULL AND bot_login IS NULL) OR " <>
            "(bot_actor_id > 0 AND char_length(bot_login) BETWEEN 1 AND 256)"
      )
    )

    create(
      constraint(:github_settings, :github_settings_operator_valid,
        check:
          "(operator_actor_id IS NULL AND operator_login IS NULL) OR " <>
            "(operator_actor_id > 0 AND char_length(operator_login) BETWEEN 1 AND 256)"
      )
    )
  end
end
