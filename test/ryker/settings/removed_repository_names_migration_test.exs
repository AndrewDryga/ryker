defmodule Ryker.Settings.RemovedRepositoryNamesMigrationTest do
  @moduledoc """
  Removing a repository deleted the only record of its GitHub name while its
  history kept the ref, so every page named that history by the ref
  (2026-09-28). The migration adds the table the name is kept in on removal.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @previous_version 20_260_928_200_000
  @version 20_260_928_210_000

  test "a removed repository's name has a table of its own, one per ref, and rolling back drops it" do
    repo = start_migration_repo!()
    prefix = "removed_repository_names_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
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

      assert Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
               step: 1,
               prefix: prefix,
               log: false
             ) ==
               [@version]

      refute table?(repo, prefix)
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
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

  defp migrate!(repo, prefix, version),
    do:
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
        to: version,
        prefix: prefix,
        log: false
      )

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
