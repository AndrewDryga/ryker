defmodule Ryker.Behaviors.SupersededRuleRunMigrationTest do
  @moduledoc """
  A standing rule's run on a message set aside for a newer revision of it may
  name no episode, whatever routing chose for the words it read first; a run
  that is decided still names the episode its new work started.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.MigrationCase

  @version 20_261_010_030_000

  test "a superseded run may name no episode, and rolling back restores the old rule" do
    assert migrate_down(@version) == :ok
    refute check() =~ "(outcome = 'superseded'::text) AND (episode_id IS NULL)"

    assert migrate_up(@version) == :ok
    assert check() =~ "(outcome = 'superseded'::text) AND (episode_id IS NULL)"

    assert check() =~
             "(decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text])) AND (episode_id IS NOT NULL)"
  end

  defp check do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'standing_assignment_run_valid'"
      )

    definition
  end
end
