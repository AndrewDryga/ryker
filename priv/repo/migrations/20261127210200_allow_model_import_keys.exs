defmodule Ryker.Repo.Migrations.AllowModelImportKeys do
  use Ecto.Migration

  def up do
    kinds =
      "kind = ANY (ARRAY['slack_app', 'slack_bot', 'github_private_key', 'github_webhook', 'github_oauth_secret', 'emisar', 'webhook', 'model_account', 'model_import'])"

    execute("""
    ALTER TABLE integration_credentials DROP CONSTRAINT integration_credentials_valid,
      ADD CONSTRAINT integration_credentials_valid CHECK (
        #{kinds} AND name ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$' AND key_version > 0
        AND octet_length(ciphertext) BETWEEN 1 AND 1048576
        AND octet_length(nonce) = 12 AND octet_length(tag) = 16
        AND (fingerprint IS NULL OR fingerprint ~ '^[0-9a-f]{64}$')
        AND verification_status = ANY (ARRAY['unverified', 'verified', 'invalid'])
        AND ((verification_status = 'verified' AND verified_at IS NOT NULL)
          OR (verification_status <> 'verified' AND verified_at IS NULL))
      )
    """)

    execute("""
    ALTER TABLE integration_credential_events DROP CONSTRAINT integration_credential_events_valid,
      ADD CONSTRAINT integration_credential_events_valid CHECK (
        #{kinds} AND name ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'
        AND action = ANY (ARRAY['created', 'replaced', 'verified', 'invalidated', 'deleted'])
        AND char_length(actor_ref) BETWEEN 1 AND 256
        AND (fingerprint IS NULL OR fingerprint ~ '^[0-9a-f]{64}$')
      )
    """)
  end

  def down, do: raise(Ecto.MigrationError, "restore the backup taken before account imports")
end
