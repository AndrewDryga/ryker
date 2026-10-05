defmodule Ryker.WeeklyReport.ReportSavedAtMigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_261_005_150_000
  @migration Ryker.Repo.Migrations.KeepWhenTheReportWasSaved
  @file_name "20261005150000_keep_when_the_report_was_saved.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @actor "control-plane:local"

  # The report read when it was last saved from the settings audit, which the
  # audit horizon prunes (2026-10-04 review). A report saved before it kept
  # the time itself starts from its newest save still on record.
  test "an existing report keeps the time of its newest save on record" do
    {:ok, _initialized} = Settings.initialize(@actor)
    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)

    SQL.query!(
      Repo,
      """
      INSERT INTO settings_edits (id, revision, domain, actor_ref, fingerprint, inserted_at)
      VALUES
        (gen_random_uuid(), 101, 'report', $1, $2, '2026-09-01 08:00:00'),
        (gen_random_uuid(), 102, 'report', $1, $2, '2026-09-20 08:00:00'),
        (gen_random_uuid(), 103, 'slack', $1, $2, '2026-09-30 08:00:00')
      """,
      [@actor, String.duplicate("a", 64)]
    )

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    assert Repo.one!(Settings.Report).saved_at == ~U[2026-09-20 08:00:00.000000Z]
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
