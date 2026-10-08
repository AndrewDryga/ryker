defmodule Ryker.WeeklyReport.ReportSavedAtMigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_261_005_150_000
  @actor "control-plane:local"

  # The report read when it was last saved from the settings audit, which the
  # audit horizon prunes (2026-10-04 review). A report saved before it kept
  # the time itself starts from its newest save still on record.
  test "an existing report keeps the time of its newest save on record" do
    {:ok, _initialized} = Settings.initialize(@actor)
    assert migrate_down(@version) == :ok

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

    assert migrate_up(@version) == :ok

    assert Repo.one!(Settings.Report).saved_at == ~U[2026-09-20 08:00:00.000000Z]
  end
end
