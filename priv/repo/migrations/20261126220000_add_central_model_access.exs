defmodule Ryker.Repo.Migrations.AddCentralModelAccess do
  use Ecto.Migration

  def up do
    kinds =
      "kind = ANY (ARRAY['slack_app', 'slack_bot', 'github_private_key', 'github_webhook', 'github_oauth_secret', 'emisar', 'webhook', 'model_account'])"

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

    create table(:coop_model_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:session_id, references(:episode_work_sessions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(
        :placement_id,
        references(:coop_session_placements, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:worker_id, :text, null: false)
      add(:worker_epoch, :uuid, null: false)
      add(:run_id, :text, null: false)
      add(:job_digest, :text, null: false)
      add(:provider, :text, null: false)
      add(:account, :text, null: false)
      add(:epoch, :bigint, null: false)
      add(:token_hash, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :coop_model_runs,
        [
          :placement_id,
          :run_id,
          :provider,
          :account,
          :epoch,
          :worker_epoch
        ],
        name: :coop_model_runs_run_identity
      )
    )

    create(unique_index(:coop_model_runs, [:token_hash]))
    create(index(:coop_model_runs, [:expires_at]))

    create(
      constraint(:coop_model_runs, :coop_model_run_valid,
        check:
          "provider IN ('claude','codex') AND epoch > 0 AND job_digest ~ '^[0-9a-f]{64}$' AND token_hash ~ '^[0-9a-f]{64}$' AND octet_length(run_id) BETWEEN 1 AND 128 AND octet_length(account) BETWEEN 1 AND 128"
      )
    )
  end

  def down do
    raise Ecto.MigrationError, "restore the backup taken before central model access"
  end
end
