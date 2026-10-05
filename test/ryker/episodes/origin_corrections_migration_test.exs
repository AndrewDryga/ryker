defmodule Ryker.Episodes.OriginCorrectionsMigrationTest do
  # The migrator runs inside this test's sandbox transaction, so nothing else
  # may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL

  @version 20_261_005_171_000
  @migration Ryker.Repo.Migrations.DropOriginCorrections
  @file_name "20261005171000_drop_origin_corrections.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]

  # Every origin was written effective with no correction, so the columns held constants
  # (2026-10-04 review). The check that named them keeps its other rules.
  test "origins keep no correction columns, and their check keeps every other rule" do
    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    assert "effective" in columns()
    assert check() =~ "correction_ref"

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)
    refute "effective" in columns()
    refute "correction_ref" in columns()
    refute check() =~ "effective"
    assert check() =~ "thread_reply"
  end

  defp columns do
    SQL.query!(
      Repo,
      "SELECT column_name FROM information_schema.columns WHERE table_name = 'episode_input_origins'",
      []
    ).rows
    |> List.flatten()
  end

  defp check do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'episode_input_origin_valid'",
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
