defmodule Ryker.Repo.Migrations.UseGenericCoopWorkerAPI do
  use Ecto.Migration

  def up do
    schema = String.replace(prefix() || "public", "\"", "\"\"")
    drop(constraint(:coop_worker_commands, :coop_worker_command_identity_valid))

    create(
      constraint(:coop_worker_commands, :coop_worker_command_identity_valid,
        check: """
        command_version IN (1, 2)
        AND (
          (placement_id IS NOT NULL AND worker_id IS NOT NULL
           AND placement_generation IS NOT NULL AND placement_generation > 0)
          OR
          (placement_id IS NULL AND worker_id IS NULL AND placement_generation IS NULL
           AND command_version = 2 AND kind IN ('create_session', 'submit_turn')
           AND status = 'failed' AND delivered_at IS NULL AND acknowledged_at IS NULL
           AND operation_key IS NOT NULL AND operation_key = idempotency_key
           AND result_fingerprint IS NOT NULL
           AND COALESCE(error::jsonb->>'code' = 'operation_not_enqueued', FALSE))
        )
        AND kind ~ '^[a-z][a-z_]{0,63}$'
        AND char_length(payload_fingerprint) = 64
        AND char_length(idempotency_key) BETWEEN 1 AND 512
        AND status IN ('queued', 'delivered', 'acknowledged', 'succeeded', 'failed', 'uncertain')
        """
      )
    )

    alter table(:coop_worker_commands) do
      modify(:command_version, :bigint, default: 2, null: false)
      modify(:placement_id, :uuid, null: true)
      modify(:worker_id, :text, null: true)
      modify(:placement_generation, :bigint, null: true)
    end

    execute("""
    ALTER TABLE "#{schema}".coop_worker_commands
    ADD CONSTRAINT coop_worker_command_session_fkey
    FOREIGN KEY (session_id) REFERENCES "#{schema}".episode_work_sessions(id) ON DELETE RESTRICT
    """)

    # Preserve old receipts and payloads, but never reinterpret a delivered v1
    # mutation as a new HTTP request. Only undispatched work is definitely failed.
    fingerprint = :crypto.hash(:sha256, "coop-worker-v1-retired") |> Base.encode16(case: :lower)

    execute("""
    UPDATE "#{schema}".coop_worker_commands
    SET status = CASE WHEN status = 'queued' THEN 'failed' ELSE 'uncertain' END,
        operation_key = idempotency_key,
        error = '{"code":"worker_protocol_replaced","detail":"This operation used retired worker protocol v1; inspect its saved operation before retrying.","status":409}',
        result_fingerprint = '#{fingerprint}',
        completed_at = now(), updated_at = now()
    WHERE command_version = 1 AND status IN ('queued', 'delivered', 'acknowledged')
    """)
  end

  def down do
    raise "Generic worker commands cannot be downgraded to the retired semantic protocol"
  end
end
