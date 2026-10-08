defmodule Ryker.Work.SessionOwnerIndexesMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_007_170_000

  # Removing a learning, improvement or knowledge run, or an inbox entry, checks
  # the sessions' foreign key by the owner's id alone. The unique indexes named
  # the session's kind as well, so the check read the whole table for every row
  # retention removed (2026-10-04 review). An index the check can use leads
  # with the owner's column and holds every row that has one: no predicate, or
  # only that the owner is set, which `owner = $1` implies. The planner's choice is not
  # asserted: on a near-empty table PostgreSQL 18's skip scan prices the
  # unique (id, admission_input_id) index the same, and the pick flipped
  # between runs (2026-10-08).
  test "a removed run or inbox entry finds its sessions through an index" do
    owners = %{
      "learning_run_id" => "episode_work_sessions_learning_run_id_index",
      "improvement_run_id" => "episode_work_sessions_improvement_run_id_index",
      "knowledge_run_id" => "episode_work_sessions_knowledge_run_id_index",
      "admission_input_id" => "episode_work_sessions_admission_generation_index"
    }

    assert migrate_down(@version) == :ok

    for {column, index} <- owners do
      refute index in indexes_led_by(column)
    end

    assert migrate_up(@version) == :ok

    for {column, index} <- owners do
      assert index in indexes_led_by(column)
    end
  end

  # The indexes of episode_work_sessions whose first column is `column` and
  # that hold every row with it set, by name.
  defp indexes_led_by(column) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT index.relname
        FROM pg_index i
        JOIN pg_class index ON index.oid = i.indexrelid
        JOIN pg_class tbl ON tbl.oid = i.indrelid
        JOIN pg_attribute a ON a.attrelid = tbl.oid AND a.attnum = i.indkey[0]
        WHERE tbl.relname = 'episode_work_sessions'
          AND tbl.relnamespace = current_schema()::regnamespace
          AND a.attname = $1
          AND (i.indpred IS NULL OR pg_get_expr(i.indpred, i.indrelid) = '(' || $1 || ' IS NOT NULL)')
        """,
        [column]
      )

    List.flatten(rows)
  end
end
