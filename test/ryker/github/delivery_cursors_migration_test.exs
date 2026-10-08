defmodule Ryker.GitHub.DeliveryCursorsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_008_000_000

  # The GitHub delivery poller kept where it stopped in memory only, so every
  # restart read a day of deliveries back and warned that older ones were
  # skipped (2026-10-07). One row per App keeps it.
  test "an App keeps one place its deliveries were read to, never a negative one" do
    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok

    assert keep(7_001, 42) == {:ok, 1}

    assert keep(7_001, 43, "ON CONFLICT (app_id) DO UPDATE SET through_delivery_id = 43") ==
             {:ok, 1}

    assert %{rows: [[43]]} =
             SQL.query!(Repo, "SELECT through_delivery_id FROM github_delivery_cursors", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} = keep(7_002, -1)
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} = keep(0, 1)
  end

  # A savepoint keeps the refused write from aborting the test's transaction.
  defp keep(app_id, through, conflict \\ "") do
    Repo.transaction(fn ->
      %{num_rows: count} =
        SQL.query!(
          Repo,
          "INSERT INTO github_delivery_cursors (app_id, through_delivery_id, updated_at) " <>
            "VALUES ($1, $2, now()) " <> conflict,
          [app_id, through]
        )

      count
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end
end
