defmodule Ryker.Repo.Migrations.QueueSessionEvidenceCommands do
  use Ecto.Migration

  # The worker protocol has carried `get_session_evidence` since the capability
  # shipped, and the production worker advertised `session-evidence:1` from the
  # day it was rolled. Not one evidence document was ever collected: the host's
  # enqueue authority and this table's check constraint each kept their own
  # copy of the command vocabulary, and neither copy learned the kind. Every
  # capture was refused before a worker saw it.
  @kinds ~w(
    ensure_workspace
    create_session
    get_session
    get_session_evidence
    submit_turn
    get_turn
    get_output_artifact
    get_changes
    get_changes_page
    run_review
    plan_discard
    discard_session
    get_review_patch
    validate_candidate
    cancel_turn
    fence_operation
    checkpoint_workspace
    close_session
    reconcile_operation
  )

  @added ~w(get_session_evidence)

  def up, do: replace_identity_constraint(@kinds)

  def down do
    # A queued or answered evidence command is real fleet history; recreating a
    # constraint it violates would either fail opaquely or invite deleting it.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("coop_worker_commands")}
        WHERE kind IN (#{Enum.map_join(@added, ", ", &"'#{&1}'")})
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'session evidence commands exist and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    replace_identity_constraint(@kinds -- @added)
  end

  defp replace_identity_constraint(kinds) do
    drop(constraint(:coop_worker_commands, :coop_worker_command_identity_valid))

    create(
      constraint(:coop_worker_commands, :coop_worker_command_identity_valid,
        check: """
        placement_generation > 0
        AND command_version = 1
        AND kind IN (#{Enum.map_join(kinds, ", ", &"'#{&1}'")})
        AND char_length(payload_fingerprint) = 64
        AND char_length(idempotency_key) BETWEEN 1 AND 512
        AND status IN ('queued', 'delivered', 'acknowledged', 'succeeded', 'failed', 'uncertain')
        """
      )
    )
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
