defmodule Ryker.Work.SessionOwnerIndexesMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_007_170_000

  # Removing a learning, improvement or knowledge run, or an inbox entry, checks
  # the sessions' foreign key by the owner's id alone. The unique indexes named
  # the session's kind as well, so the check read the whole table for every row
  # retention removed (2026-10-04 review). The plans name each index once it
  # exists, read with sequential scans off so that a near-empty table does not
  # hide whether the check can use it.
  test "a removed run or inbox entry finds its sessions through an index" do
    owners = %{
      "learning_run_id" => "episode_work_sessions_learning_run_id_index",
      "improvement_run_id" => "episode_work_sessions_improvement_run_id_index",
      "knowledge_run_id" => "episode_work_sessions_knowledge_run_id_index",
      "admission_input_id" => "episode_work_sessions_admission_generation_index"
    }

    assert :ok = migrate_down(@version)

    for {column, index} <- owners do
      refute plan(column) =~ index
    end

    assert :ok = migrate_up(@version)

    for {column, index} <- owners do
      assert plan(column) =~ index
    end
  end

  # The query PostgreSQL's foreign-key check runs for a removed owner.
  defp plan(column) do
    SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])

    %{rows: rows} =
      SQL.query!(
        Repo,
        "EXPLAIN SELECT 1 FROM episode_work_sessions WHERE #{column} = $1",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

    Enum.map_join(rows, "\n", &hd/1)
  end
end
