defmodule Ryker.Repo.Migrations.AddGitHubEventCustodyAndRepositoryOnboarding do
  use Ecto.Migration

  def change do
    alter table(:repository_settings) do
      add(:github_access, :text, null: false, default: "available")
      add(:onboarding_state, :text, null: false, default: "pending")
      add(:onboarding_error, :text)
      add(:source_commit, :text)
      add(:knowledge_pull_request_url, :text)
      add(:last_github_event_at, :utc_datetime_usec)
    end

    create(
      constraint(:repository_settings, :repository_github_state_valid,
        check:
          "github_access IN ('available', 'suspended', 'removed') AND " <>
            "onboarding_state IN ('pending', 'cloning', 'scanning', 'publishing', 'ready', 'blocked')"
      )
    )

    create table(:github_repository_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:delivery_ref, :text, null: false)
      add(:binding_ref, :text, null: false)
      add(:repository_id, :bigint, null: false)
      add(:event_name, :text, null: false)
      add(:action, :text)
      add(:event_ref, :text, null: false)
      add(:payload_digest, :text, null: false)
      add(:disposition, :text, null: false, default: "received")
      add(:reason, :text)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:processed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:github_repository_events, [:binding_ref, :delivery_ref]))
    create(index(:github_repository_events, [:binding_ref, :occurred_at]))

    create(
      constraint(:github_repository_events, :github_repository_event_valid,
        check:
          "char_length(delivery_ref) BETWEEN 1 AND 1024 AND " <>
            "char_length(binding_ref) BETWEEN 1 AND 64 AND repository_id > 0 AND " <>
            "char_length(event_name) BETWEEN 1 AND 64 AND " <>
            "payload_digest ~ '^[0-9a-f]{64}$' AND " <>
            "disposition IN ('received', 'metadata', 'routed', 'continued', 'duplicate', 'failed')"
      )
    )
  end
end
