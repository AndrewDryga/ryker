defmodule Ryker.Waits.WaitFailuresMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_005_170_000

  # One wait Ryker kept failing to resume held up every other (2026-10-04 review); it is now
  # marked and passed over, which the table refused.
  test "a wait can be marked as one Ryker failed to schedule or resume, and back" do
    assert :ok = migrate_down(@version)
    refute check() =~ "resume_failed"

    assert :ok = migrate_up(@version)
    assert check() =~ "'schedule_failed'"
    assert check() =~ "'resume_failed'"
    assert check() =~ "'cursor'"
  end

  defp check do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'episode_state_record_wait_error_valid'",
        []
      )

    definition
  end
end
