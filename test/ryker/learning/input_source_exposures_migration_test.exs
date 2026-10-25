defmodule Ryker.Learning.InputSourceExposuresMigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Learning.{LearningSources, SourceExposure}

  @version 20_261_025_050_000

  # Old native transcripts did not distinguish inputs from recalled memory.
  # Preserve their exact custody while denying an unproven input exception.
  test "existing source custody remains conservative after adding disclosure roles" do
    [entry | _] = LearningFixtures.inputs!(isolate: true)

    assert {:ok, session} =
             WorkSessions.pin_episode(
               entry.episode_id,
               "migration-read",
               String.duplicate("a", 64)
             )

    [receipt] = LearningSources.for_entry(entry)

    Repo.insert!(%SourceExposure{
      session_id: session.id,
      observation_id: receipt["observation_id"],
      source_input_id: receipt["source_input_id"],
      receipt: receipt,
      input_only: true
    })

    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok
    exposure = Repo.fetch!(SourceExposure.Query.by_session_id(session.id))
    assert exposure.input_only == false
    assert exposure.receipt == receipt
  end
end
