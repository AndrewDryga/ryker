defmodule Ryker.Episodes.OriginCorrectionsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_005_171_000

  # Every origin was written effective with no correction, so the columns held constants
  # (2026-10-04 review). The check that named them keeps its other rules.
  test "origins keep no correction columns, and their check keeps every other rule" do
    assert migrate_down(@version) == :ok
    assert "effective" in columns()
    assert check() =~ "correction_ref"

    assert migrate_up(@version) == :ok
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
end
