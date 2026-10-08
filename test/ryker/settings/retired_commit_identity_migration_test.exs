defmodule Ryker.Settings.RetiredCommitIdentityMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_008_010_000

  # The commit author settings went with controller-owned Coop jobs on
  # 2026-09-27, and their columns stayed behind, read by nothing. The branch
  # prefix keeps the bound the shared check gave it.
  test "the retired commit identity is gone and the branch prefix keeps its bound" do
    assert migrate_down(@version) == :ok
    assert "commit_email" in columns()
    assert migrate_up(@version) == :ok

    refute "commit_name" in columns()
    refute "commit_email" in columns()

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             set_prefix(String.duplicate("p", 241))

    assert set_prefix("ryker") == {:ok, 1}
  end

  defp columns do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = 'publication_settings'",
        []
      )

    List.flatten(rows)
  end

  # A savepoint keeps the refused write from aborting the test's transaction.
  defp set_prefix(prefix) do
    Repo.transaction(fn ->
      SQL.query!(
        Repo,
        "INSERT INTO installation_settings " <>
          "(host_ref, revision, applied_revision, saved_by, saved_at, inserted_at) " <>
          "VALUES ('commit-identity', 1, 0, 'test', now(), now()) ON CONFLICT DO NOTHING",
        []
      )

      %{num_rows: count} =
        SQL.query!(
          Repo,
          "INSERT INTO publication_settings (id, branch_prefix) VALUES ('commit-identity', $1) " <>
            "ON CONFLICT (id) DO UPDATE SET branch_prefix = EXCLUDED.branch_prefix",
          [prefix]
        )

      count
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end
end
