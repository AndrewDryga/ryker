defmodule Ryker.Repo.Migrations.RestorePublicationFollowupCheck do
  use Ecto.Migration

  # Dropping `manual_check_ref` (20260930100000) dropped the one check that
  # named it, and with it every rule about a pull request follow-up's states,
  # check counts, merge commit and verification (found 2026-10-04). This puts
  # the check back without that column; no live row broke it.

  def up do
    execute("""
    ALTER TABLE #{table()}
      ADD CONSTRAINT episode_publication_followup_state_valid CHECK (
        pr_state IN ('open', 'closed', 'merged', 'stale', 'expired')
        AND checks_state IN ('unknown', 'none', 'pending', 'passing', 'failing')
        AND checks_total >= 0 AND checks_passed >= 0 AND checks_failed >= 0
        AND checks_passed + checks_failed <= checks_total
        AND (checks_url IS NULL OR octet_length(checks_url) BETWEEN 1 AND 2048)
        AND (merge_sha IS NULL OR merge_sha ~ '^[a-f0-9]{40}([a-f0-9]{24})?$')
        AND (last_event_key IS NULL OR char_length(last_event_key) BETWEEN 1 AND 128)
        AND (last_error IS NULL OR octet_length(last_error) BETWEEN 1 AND 4096)
        AND failure_count >= 0
        AND deadline_at > inserted_at
        AND (
          (verification_turn_ref IS NULL AND verification_event_ref IS NULL
            AND verification_sequence IS NULL AND verified_at IS NULL)
          OR (char_length(verification_turn_ref) BETWEEN 1 AND 1024
            AND char_length(verification_event_ref) BETWEEN 1 AND 1024
            AND verification_sequence > 0)
        )
      )
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{table()}
      DROP CONSTRAINT episode_publication_followup_state_valid
    """)
  end

  defp table do
    schema = String.replace(prefix() || "public", "\"", "\"\"")
    ~s("#{schema}".episode_publication_followups)
  end
end
