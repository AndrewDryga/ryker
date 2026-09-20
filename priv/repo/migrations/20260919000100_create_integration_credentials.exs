defmodule Ryker.Repo.Migrations.CreateIntegrationCredentials do
  use Ecto.Migration

  @hex64 "^[0-9a-f]{64}$"
  @name "^[a-z0-9][a-z0-9_.:-]{0,127}$"

  def change do
    create table(:integration_credentials, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:kind, :text, null: false)
      add(:name, :text, null: false)
      add(:key_version, :integer, null: false)
      add(:ciphertext, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:tag, :binary, null: false)
      add(:fingerprint, :text, null: false)
      add(:verification_status, :text, null: false, default: "unverified")
      add(:verified_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:integration_credentials, [:kind, :name]))

    create(
      constraint(:integration_credentials, :integration_credentials_valid,
        check:
          "kind IN ('slack_app', 'slack_bot', 'github_private_key', 'github_webhook', " <>
            "'emisar', 'webhook') AND name ~ '#{@name}' AND key_version > 0 " <>
            "AND octet_length(ciphertext) BETWEEN 1 AND 1048576 " <>
            "AND octet_length(nonce) = 12 AND octet_length(tag) = 16 " <>
            "AND fingerprint ~ '#{@hex64}' " <>
            "AND verification_status IN ('unverified', 'verified', 'invalid') " <>
            "AND ((verification_status = 'verified' AND verified_at IS NOT NULL) OR " <>
            "(verification_status <> 'verified' AND verified_at IS NULL))"
      )
    )

    create table(:integration_credential_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :credential_id,
        references(:integration_credentials, type: :uuid, on_delete: :nilify_all)
      )

      add(:kind, :text, null: false)
      add(:name, :text, null: false)
      add(:action, :text, null: false)
      add(:actor_ref, :text, null: false)
      add(:fingerprint, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:integration_credential_events, [:kind, :name, :inserted_at]))

    create(
      constraint(:integration_credential_events, :integration_credential_events_valid,
        check:
          "kind IN ('slack_app', 'slack_bot', 'github_private_key', 'github_webhook', " <>
            "'emisar', 'webhook') AND name ~ '#{@name}' " <>
            "AND action IN ('created', 'replaced', 'verified', 'invalidated', 'deleted') " <>
            "AND char_length(actor_ref) BETWEEN 1 AND 256 " <>
            "AND (fingerprint IS NULL OR fingerprint ~ '#{@hex64}')"
      )
    )
  end
end
