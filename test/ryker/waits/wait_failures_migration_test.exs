defmodule Ryker.Waits.WaitFailuresMigrationTest do
  # The migrator runs inside this test's sandbox transaction, so nothing else
  # may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL

  @version 20_261_005_170_000
  @migration Ryker.Repo.Migrations.MarkWaitsRykerFailedOn
  @file_name "20261005170000_mark_waits_ryker_failed_on.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]

  # One wait Ryker kept failing to resume held up every other (2026-10-04 review); it is now
  # marked and passed over, which the table refused.
  test "a wait can be marked as one Ryker failed to schedule or resume, and back" do
    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    refute check() =~ "resume_failed"

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)
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

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration do
    unless Code.ensure_loaded?(@migration) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", @file_name))
      |> Code.compile_file()
    end

    @migration
  end
end
