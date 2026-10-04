defmodule Ryker.Repo.Migrations.KeepCheckpointBodiesOnlyAsFiles do
  use Ecto.Migration

  # Version-1 checkpoints kept their bodies in these columns. Ryker has stored
  # every body as an encrypted file since 2026-09-26, and no install held a
  # version-1 checkpoint when their reader was removed (2026-10-04). A body
  # still kept here is history, so the migration stops instead of dropping it.
  def up do
    schema = String.replace(prefix() || "public", "\"", "\"\"")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM "#{schema}".coop_worker_workspace_checkpoints WHERE ciphertext IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'a version-1 checkpoint still keeps its body in the database';
      END IF;
    END
    $$
    """)

    drop(identity_constraint())

    alter table(:coop_worker_workspace_checkpoints) do
      remove(:encryption_nonce)
      remove(:encryption_tag)
      remove(:ciphertext)
      modify(:body_command_id, :uuid, null: false)
    end

    create(
      constraint(
        :coop_worker_workspace_checkpoints,
        :coop_worker_workspace_checkpoint_identity_valid,
        check: identity_check()
      )
    )
  end

  def down do
    drop(identity_constraint())

    alter table(:coop_worker_workspace_checkpoints) do
      add(:encryption_nonce, :binary)
      add(:encryption_tag, :binary)
      add(:ciphertext, :binary)
      modify(:body_command_id, :uuid, null: true)
    end

    create(
      constraint(
        :coop_worker_workspace_checkpoints,
        :coop_worker_workspace_checkpoint_identity_valid,
        check: """
        #{identity_check()}
        AND (
          (body_command_id IS NOT NULL AND encryption_nonce IS NULL AND encryption_tag IS NULL AND ciphertext IS NULL)
          OR
          (body_command_id IS NULL AND encryption_nonce IS NOT NULL AND encryption_tag IS NOT NULL AND ciphertext IS NOT NULL
            AND bundle_byte_size <= 67108864 AND octet_length(encryption_nonce) = 12
            AND octet_length(encryption_tag) = 16 AND octet_length(ciphertext) = bundle_byte_size)
        )
        """
      )
    )
  end

  defp identity_constraint,
    do:
      constraint(
        :coop_worker_workspace_checkpoints,
        :coop_worker_workspace_checkpoint_identity_valid
      )

  defp identity_check do
    """
    char_length(checkpoint_ref) BETWEEN 1 AND 256 AND checkpoint_ref ~ '^[A-Za-z0-9_.:-]+$'
    AND char_length(session_ref) BETWEEN 1 AND 256 AND session_ref ~ '^[A-Za-z0-9_.:-]+$'
    AND placement_generation > 0
    AND char_length(repository_ref) BETWEEN 1 AND 256 AND repository_ref ~ '^[A-Za-z0-9_.:-]+$'
    AND jsonb_typeof(descriptor::jsonb) = 'object' AND octet_length(descriptor) BETWEEN 1 AND 1048576
    AND bundle_sha256 ~ '^[0-9a-f]{64}$' AND bundle_byte_size > 0
    AND encryption_key_sha256 ~ '^[0-9a-f]{64}$'
    """
  end
end
