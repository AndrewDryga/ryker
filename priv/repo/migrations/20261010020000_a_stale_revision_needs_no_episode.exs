defmodule Ryker.Repo.Migrations.AStaleRevisionNeedsNoEpisode do
  use Ecto.Migration

  # A revision of a message was set aside only when an episode owned the message, so an edit made
  # while routing read the first version got two quick replies, one per version (2026-10-09). A
  # message no episode owns is now set aside too, with no episode and whatever routing decided
  # for it, a quick reply included.

  @decided_and_pending """
  ((status = 'pending'::text) AND (decision_ref IS NULL) AND (decision_fingerprint IS NULL) AND (decision_action IS NULL) AND (decision_document IS NULL) AND (episode_id IS NULL))
  OR ((status = 'blocked'::text) AND (decision_ref IS NULL) AND (decision_fingerprint IS NULL) AND (decision_action IS NULL) AND (decision_document IS NULL) AND (episode_id IS NULL) AND (char_length(last_error_code) > 0) AND (char_length(last_error_detail) > 0))
  OR ((status = 'decided'::text) AND (char_length(decision_ref) > 0) AND (char_length(decision_fingerprint) = 64) AND (decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text, 'quick_reply'::text, 'react'::text, 'ignore'::text])) AND (decision_document IS NOT NULL) AND (((decision_action = ANY (ARRAY['quick_reply'::text, 'react'::text, 'ignore'::text])) AND (episode_id IS NULL)) OR ((decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text])) AND (episode_id IS NOT NULL))))
  """

  @superseded_with_episode """
  ((status = 'superseded'::text) AND (char_length(decision_ref) > 0) AND (char_length(decision_fingerprint) = 64) AND (decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text, 'react'::text, 'ignore'::text])) AND (decision_document IS NOT NULL) AND (episode_id IS NOT NULL) AND (last_error_code = 'stale_input_revision'::text) AND (char_length(last_error_detail) > 0))
  """

  @superseded_any """
  ((status = 'superseded'::text) AND (char_length(decision_ref) > 0) AND (char_length(decision_fingerprint) = 64) AND (decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text, 'quick_reply'::text, 'react'::text, 'ignore'::text])) AND (decision_document IS NOT NULL) AND (last_error_code = 'stale_input_revision'::text) AND (char_length(last_error_detail) > 0))
  """

  def up, do: replace(@superseded_any)
  def down, do: replace(@superseded_with_episode)

  defp replace(superseded) do
    drop(constraint(:ingress_inbox_entries, :ingress_inbox_decision_matches_status))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_decision_matches_status,
        check: "(" <> @decided_and_pending <> " OR " <> superseded <> ")"
      )
    )
  end
end
