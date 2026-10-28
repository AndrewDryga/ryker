defmodule Ryker.Flywheel.MigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Flywheel

  @version 20_261_025_200_000

  test "the ledger is separate from human feedback and a fresh migration supports operator custody" do
    assert migrate_down(@version) == :ok
    assert ledger_tables() == []
    assert migrate_up(@version) == :ok
    assert ledger_tables() == ["flywheel_findings", "flywheel_receipts", "flywheel_runs"]

    assert {:ok, run} =
             Flywheel.execute(%{
               "action" => "start",
               "request_ref" => "migration",
               "mode" => "suggest",
               "from" => "2026-10-01T00:00:00Z",
               "until" => "2026-10-02T00:00:00Z",
               "sources" => ["logs"],
               "policy" => %{
                 "max_tasks" => 1,
                 "max_cost_usd" => "1.00",
                 "allowed_kinds" => ["code"]
               }
             })

    assert run["status"] == "running"
    assert Repo.aggregate(Ryker.Operator.EpisodeReview, :count) == 0
  end

  defp ledger_tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = current_schema() AND tablename LIKE 'flywheel_%' ORDER BY tablename"
      )

    List.flatten(rows)
  end
end
