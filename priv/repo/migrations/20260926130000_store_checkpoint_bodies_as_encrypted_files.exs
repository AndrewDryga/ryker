defmodule Ryker.Repo.Migrations.StoreCheckpointBodiesAsEncryptedFiles do
  use Ecto.Migration

  def up do
    schema = String.replace(prefix() || "public", "\"", "\"\"")

    alter table(:coop_worker_workspace_checkpoints) do
      add(:body_command_id, :uuid)
      modify(:encryption_nonce, :binary, null: true)
      modify(:encryption_tag, :binary, null: true)
      modify(:ciphertext, :binary, null: true)
    end

    execute("""
    ALTER TABLE "#{schema}".coop_worker_workspace_checkpoints
      ADD CONSTRAINT coop_worker_checkpoint_body_worker_fkey
      FOREIGN KEY (body_command_id, worker_id) REFERENCES "#{schema}".coop_worker_commands (id, worker_id)
    """)

    drop(
      constraint(
        :coop_worker_workspace_checkpoints,
        :coop_worker_workspace_checkpoint_identity_valid
      )
    )

    create(
      constraint(
        :coop_worker_workspace_checkpoints,
        :coop_worker_workspace_checkpoint_identity_valid,
        check: """
        char_length(checkpoint_ref) BETWEEN 1 AND 256 AND checkpoint_ref ~ '^[A-Za-z0-9_.:-]+$'
        AND char_length(session_ref) BETWEEN 1 AND 256 AND session_ref ~ '^[A-Za-z0-9_.:-]+$'
        AND placement_generation > 0
        AND char_length(repository_ref) BETWEEN 1 AND 256 AND repository_ref ~ '^[A-Za-z0-9_.:-]+$'
        AND jsonb_typeof(descriptor::jsonb) = 'object' AND octet_length(descriptor) BETWEEN 1 AND 1048576
        AND bundle_sha256 ~ '^[0-9a-f]{64}$' AND bundle_byte_size > 0
        AND encryption_key_sha256 ~ '^[0-9a-f]{64}$'
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

  def down,
    do: raise("Encrypted file custody cannot be downgraded to whole-buffer checkpoint storage")
end
