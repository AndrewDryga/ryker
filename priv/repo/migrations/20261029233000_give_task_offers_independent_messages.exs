defmodule Ryker.Repo.Migrations.GiveTaskOffersIndependentMessages do
  use Ecto.Migration

  def up do
    alter table(:slack_task_cards) do
      modify(:episode_id, :uuid, null: true)
      modify(:message_ref, :text, null: true)
      modify(:thread_ref, :text, null: true)
    end

    # A started task adopted its whole source reply. When that reply offered
    # multiple tasks, its progress erased the sibling controls (2026-10-29).
    # Rearm the real click's repaint before detaching that projection; original
    # Work receipts and confirmation history remain untouched.
    execute("""
    UPDATE slack_interaction_audit AS audit
    SET repaint_status = 'pending', attempt_count = 0, next_attempt_at = NULL,
        lease_owner = NULL, lease_ref = NULL, lease_expires_at = NULL,
        last_error_code = NULL, last_error_detail = NULL, repainted_at = NULL
    FROM slack_task_cards AS card
    JOIN episode_state_records AS offer ON offer.id = card.record_id
    JOIN episode_work_turns AS turn ON turn.id = offer.turn_id
    WHERE audit.workspace_ref = card.workspace_ref AND audit.channel_ref = card.channel_ref
      AND audit.message_ref = card.message_ref
      AND audit.thread_ref IS NOT DISTINCT FROM (turn.external_receipt::jsonb)->>'thread_ref'
      AND card.message_ref = (turn.external_receipt::jsonb)->>'message_ref'
      AND audit.action_id = 'ryker_start_engineering_task'
      AND audit.outcome = 'confirmed'
      AND (SELECT count(*) FROM episode_state_records AS sibling
           WHERE sibling.turn_id = turn.id AND sibling.kind = 'task_offer'
             AND (sibling.payload::jsonb)->>'kind' = 'engineering'
             AND COALESCE((turn.delivery_document::jsonb)->'outcome'->'record_refs', '[]'::jsonb) ? sibling.ref) > 1
    """)

    execute("""
    UPDATE slack_task_cards AS card
    SET message_ref = NULL, card_checked_at = NULL, card_fingerprint = NULL,
        status = 'active', attempt_count = 0, next_attempt_at = NULL,
        lease_owner = NULL, lease_ref = NULL, lease_expires_at = NULL,
        last_error_code = NULL, last_error_detail = NULL
    FROM episode_state_records AS offer
    JOIN episode_work_turns AS turn ON turn.id = offer.turn_id
    WHERE offer.id = card.record_id AND card.message_ref = (turn.external_receipt::jsonb)->>'message_ref'
      AND (SELECT count(*) FROM episode_state_records AS sibling
           WHERE sibling.turn_id = turn.id AND sibling.kind = 'task_offer'
             AND (sibling.payload::jsonb)->>'kind' = 'engineering'
             AND COALESCE((turn.delivery_document::jsonb)->'outcome'->'record_refs', '[]'::jsonb) ? sibling.ref) > 1
    """)
  end

  def down, do: raise("Restore the pre-deploy backup to restore shared task messages")
end
