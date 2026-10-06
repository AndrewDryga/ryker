defmodule Ryker.Repo.Migrations.IncidentRoomsKeepTheWholeBrief do
  use Ecto.Migration

  # An incident offer may carry a brief of 32,000 characters
  # (`Ryker.Records.RecordPayload`), but a room kept at most 4,000, so an offer
  # with a longer brief could never get its room (2026-10-05). The longest
  # live brief was 2,557 characters, so no room needs changing.

  def up, do: valid(32_000)
  def down, do: valid(4_000)

  defp valid(prompt) do
    execute("ALTER TABLE slack_incident_rooms DROP CONSTRAINT slack_incident_room_valid")

    execute("""
    ALTER TABLE slack_incident_rooms ADD CONSTRAINT slack_incident_room_valid CHECK (
    (status = ANY (ARRAY['requested'::text, 'ready'::text, 'blocked'::text, 'closed'::text]))
    AND (channel_state = ANY (ARRAY['pending'::text, 'active'::text, 'archived'::text, 'deleted'::text, 'unavailable'::text]))
    AND (reconciled_channel_state = ANY (ARRAY['pending'::text, 'active'::text, 'archived'::text, 'deleted'::text, 'unavailable'::text]))
    AND ((char_length(ref) >= 1) AND (char_length(ref) <= 256))
    AND ((char_length(policy) >= 1) AND (char_length(policy) <= 256))
    AND (char_length(policy_digest) = 64)
    AND ((char_length(repository_ref) >= 1) AND (char_length(repository_ref) <= 256))
    AND ((char_length(title) >= 1) AND (char_length(title) <= 200))
    AND ((char_length(prompt) >= 1) AND (char_length(prompt) <= #{prompt}))
    AND ((char_length(channel_name) >= 1) AND (char_length(channel_name) <= 80))
    AND ((char_length(topic) >= 1) AND (char_length(topic) <= 250))
    AND (attempt_count >= 0)
    AND (root_card_ui_revision >= 0)
    AND ((root_card_fingerprint IS NULL) OR (char_length(root_card_fingerprint) = 64))
    AND (((lease_owner IS NULL) AND (lease_ref IS NULL) AND (lease_expires_at IS NULL)) OR ((status = ANY (ARRAY['requested'::text, 'ready'::text])) AND (char_length(lease_owner) > 0) AND (lease_ref IS NOT NULL) AND (lease_expires_at IS NOT NULL)))
    AND ((status = ANY (ARRAY['requested'::text, 'ready'::text])) OR (next_attempt_at IS NULL))
    AND (((channel_ref IS NULL) AND (channel_state = 'pending'::text)) OR ((channel_ref IS NOT NULL) AND (channel_state <> 'pending'::text)))
    AND ((status <> 'ready'::text) OR ((episode_id IS NOT NULL) AND (channel_ref IS NOT NULL) AND (root_message_ref IS NOT NULL) AND (root_card_fingerprint IS NOT NULL) AND (root_card_ui_revision > 0) AND (handoff_message_ref IS NOT NULL) AND (audience_prepared_at IS NOT NULL) AND (topic_prepared_at IS NOT NULL) AND (root_pinned_at IS NOT NULL)))
    )
    """)
  end
end
