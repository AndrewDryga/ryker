defmodule Ryker.Settings.RemovedRepositoryNamesMigrationTest do
  @moduledoc """
  Removing a repository deleted the only record of its GitHub name while its
  history kept the ref, so every page named that history by the ref
  (2026-09-28). The migration adds the table the name is kept in on removal.
  """
  use Ryker.MigrationCase

  alias Ecto.Adapters.SQL

  @previous_version 20_260_928_200_000
  @version 20_260_928_210_000

  test "a removed repository's name has a table of its own, one per ref, and rolling back drops it" do
    in_scratch_schema("removed_repository_names", fn repo, prefix ->
      migrate!(repo, prefix, @previous_version)
      refute table?(repo, prefix)

      assert @version in migrate!(repo, prefix, @version)
      assert table?(repo, prefix)

      insert = """
      INSERT INTO #{prefix}.removed_repository_names (ref, name, inserted_at)
      VALUES ('acme-api', 'Acme/API', now())
      """

      SQL.query!(repo, insert, [])
      assert_raise Postgrex.Error, ~r/unique|duplicate/, fn -> SQL.query!(repo, insert, []) end

      assert rollback!(repo, prefix) ==
               [@version]

      refute table?(repo, prefix)
    end)
  end

  defp table?(repo, prefix) do
    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT 1 FROM pg_tables WHERE schemaname = $1 AND tablename = 'removed_repository_names'",
        [prefix]
      )

    rows != []
  end
end
