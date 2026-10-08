defmodule Ryker.Improvement.DropCandidateAnalysisRunMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_007_180_000

  # A candidate's copy of its applied run's id was written and never read
  # (2026-10-04 review); the run says it on its own.
  test "a candidate no longer keeps a copy of its applied run's id" do
    assert migrate_down(@version) == :ok
    assert "analysis_run_id" in columns()

    assert migrate_up(@version) == :ok
    refute "analysis_run_id" in columns()
  end

  defp columns do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'improvement_candidates'",
        []
      )

    List.flatten(rows)
  end
end
