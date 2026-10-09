defmodule Ryker.Repo.Migrations.WelcomesRememberWhatTheySaid do
  use Ecto.Migration

  # A channel's welcome was drawn again only when that channel's own settings
  # were saved, so it went on naming repositories its environment had dropped
  # (2026-10-09). The digest of what it last said lets the membership sweep
  # draw it again once that changes, and only then.

  def change do
    alter table(:slack_channel_configurations) do
      add(:welcome_digest, :text)
    end

    create(
      constraint(:slack_channel_configurations, :slack_channel_configuration_welcome_digest_valid,
        check: "welcome_digest IS NULL OR welcome_digest ~ '^[0-9a-f]{64}$'"
      )
    )
  end
end
