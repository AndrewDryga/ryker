defmodule Ryker.Repo.Migrations.AllowConfirmedSlackInteractionFeedback do
  use Ecto.Migration

  def up,
    do:
      replace_constraint(
        "outcome = 'invalid' OR (outcome = 'confirmed' AND repaint_status <> 'none')"
      )

  def down, do: replace_constraint("outcome = 'invalid'")

  defp replace_constraint(repaint_outcomes) do
    drop(constraint(:slack_interaction_audit, :slack_interaction_audit_valid))

    create(
      constraint(:slack_interaction_audit, :slack_interaction_audit_valid,
        check: """
        char_length(event_ref) BETWEEN 1 AND 1024
        AND char_length(request_fingerprint) = 64
        AND char_length(workspace_ref) BETWEEN 1 AND 256
        AND char_length(channel_ref) BETWEEN 1 AND 256
        AND (thread_ref IS NULL OR char_length(thread_ref) BETWEEN 1 AND 1024)
        AND char_length(message_ref) BETWEEN 1 AND 1024
        AND char_length(actor_ref) BETWEEN 1 AND 1024
        AND char_length(action_id) BETWEEN 1 AND 256
        AND char_length(action_value_digest) = 64
        AND repaint_status IN ('none', 'pending', 'settled', 'blocked')
        AND ((outcome = 'denied' AND repaint_status = 'none')
             OR (#{repaint_outcomes}))
        AND attempt_count >= 0
        AND ((lease_owner IS NULL AND lease_ref IS NULL AND lease_expires_at IS NULL)
             OR (char_length(lease_owner) BETWEEN 1 AND 1024
                 AND lease_ref IS NOT NULL AND lease_expires_at IS NOT NULL))
        AND (repainted_at IS NULL OR repaint_status = 'settled')
        """
      )
    )
  end
end
