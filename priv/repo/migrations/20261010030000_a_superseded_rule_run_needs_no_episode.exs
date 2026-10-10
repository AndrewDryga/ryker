defmodule Ryker.Repo.Migrations.ASupersededRuleRunNeedsNoEpisode do
  use Ecto.Migration

  # A message no episode owns is set aside when a later revision of it was recorded first
  # (20261010020000), and Slack records one a second after every posted link, when it unfurls
  # it. A standing rule's run on the set-aside message could not be settled: a run that says
  # routing chose new work had to name an episode, and a set-aside message has none. The message
  # retried eight times and was blocked (2026-10-10). A superseded run may now name no episode.

  @head "((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(source_input_ref) >= 1) AND (char_length(source_input_ref) <= 1024)) AND ((char_length(source_event_ref) >= 1) AND (char_length(source_event_ref) <= 1024)) AND (outcome = ANY (ARRAY['pending'::text, 'decided'::text, 'superseded'::text])) AND (((outcome = 'pending'::text) AND (decision_action IS NULL) AND (decision_ref IS NULL) AND (episode_id IS NULL)) OR ((outcome = ANY (ARRAY['decided'::text, 'superseded'::text])) AND (decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text, 'quick_reply'::text, 'react'::text, 'ignore'::text])) AND ((char_length(decision_ref) >= 1) AND (char_length(decision_ref) <= 1024)) AND (((decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text])) AND (episode_id IS NOT NULL)) OR ((decision_action = ANY (ARRAY['quick_reply'::text, 'react'::text, 'ignore'::text])) AND (episode_id IS NULL))"

  @superseded_without_episode " OR ((outcome = 'superseded'::text) AND (episode_id IS NULL))"

  @tail ")))))"

  def up, do: replace(@head <> @superseded_without_episode <> @tail)
  def down, do: replace(@head <> @tail)

  defp replace(check) do
    drop(constraint(:standing_assignment_runs, :standing_assignment_run_valid))
    create(constraint(:standing_assignment_runs, :standing_assignment_run_valid, check: check))
  end
end
