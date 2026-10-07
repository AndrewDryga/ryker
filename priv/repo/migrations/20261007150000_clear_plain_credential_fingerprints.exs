defmodule Ryker.Repo.Migrations.ClearPlainCredentialFingerprints do
  use Ecto.Migration

  # A credential's fingerprint was a plain SHA-256 of its secret, stored beside
  # the ciphertext, so a database dump or a backup let anyone check a guessed
  # secret offline (2026-10-04 review). New fingerprints are keyed by the
  # credential root (`Ryker.Credentials`). The plain ones cannot be keyed here,
  # where the root is not at hand, so they are cleared, from the credentials and
  # from their history; a credential has its keyed fingerprint again the next
  # time it is saved. The history keeps who changed what and when.

  def up do
    execute("ALTER TABLE integration_credentials ALTER COLUMN fingerprint DROP NOT NULL")
    execute("UPDATE integration_credentials SET fingerprint = NULL")
    execute("UPDATE integration_credential_events SET fingerprint = NULL")

    execute("""
    ALTER TABLE integration_credentials DROP CONSTRAINT integration_credentials_valid,
      ADD CONSTRAINT integration_credentials_valid CHECK (
        kind = ANY (ARRAY['slack_app', 'slack_bot', 'github_private_key', 'github_webhook',
          'emisar', 'webhook'])
        AND name ~ '^[a-z0-9][a-z0-9_.:-]{0,127}$'
        AND key_version > 0
        AND octet_length(ciphertext) BETWEEN 1 AND 1048576
        AND octet_length(nonce) = 12
        AND octet_length(tag) = 16
        AND (fingerprint IS NULL OR fingerprint ~ '^[0-9a-f]{64}$')
        AND verification_status = ANY (ARRAY['unverified', 'verified', 'invalid'])
        AND ((verification_status = 'verified' AND verified_at IS NOT NULL)
          OR (verification_status <> 'verified' AND verified_at IS NULL))
      )
    """)
  end

  # The plain fingerprints are gone, and a keyed one does not fit the old
  # meaning; going back is restoring the backup taken before this release.
  def down do
    raise Ecto.MigrationError,
          "the plain credential fingerprints were cleared; restore the backup taken before this release"
  end
end
