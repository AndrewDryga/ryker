defmodule Responder.Ingress.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :responder,
      adapter: Ecto.Adapters.Postgres
  end

  @legacy_version 20_260_827_000_200
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)

  test "an installation that already ran the Slack inbox migration upgrades to generic ingress" do
    repo = start_migration_repo!()
    prefix = "ingress_upgrade_#{System.unique_integer([:positive])}"

    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @legacy_version,
               prefix: prefix,
               log: false
             ) == [20_260_827_000_100, @legacy_version]

      assert table_exists?(repo, prefix, "slack_inbox_entries")
      refute table_exists?(repo, prefix, "ingress_inbox_entries")

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               all: true,
               prefix: prefix,
               log: false
             ) == [
               20_260_827_000_300,
               20_260_827_000_400
             ]

      refute table_exists?(repo, prefix, "slack_inbox_entries")
      assert table_exists?(repo, prefix, "ingress_inbox_entries")
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp start_migration_repo! do
    config =
      Responder.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end

  defp table_exists?(repo, prefix, table) do
    %{rows: [[exists?]]} =
      SQL.query!(
        repo,
        "SELECT to_regclass($1) IS NOT NULL",
        [prefix <> "." <> table]
      )

    exists?
  end
end
