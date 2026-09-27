defmodule Ryker.Settings.EnvironmentRepositoryAccessMigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_260_927_151_500
  @migration Ryker.Repo.Migrations.AddEnvironmentRepositoryAccess
  @file_name "20260927151500_add_environment_repository_access.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @actor "control-plane:local"

  # Andrew, 2026-09-27: "can we here limit read or read/write access per
  # repo?" Until then a task could change any repository of its environment,
  # so an environment saved before the choice existed has to keep working as
  # it did: every repository it holds arrives read and write, in the order it
  # had. Nothing may arrive read only, which would quietly stop work there
  # from changing code it changed the day before.
  test "an environment saved before access existed keeps every repository read and write" do
    {:ok, snapshot} = Settings.initialize(@actor)

    snapshot =
      Enum.reduce(~w(api docs infra), snapshot, fn ref, current ->
        {:ok, saved} = Settings.put_repository(%{ref: ref}, current.installation.revision, @actor)
        saved
      end)

    {:ok, _saved} =
      Settings.put_environment(
        %{
          ref: "production",
          display_name: "Production",
          repositories: ["docs", "api", "infra"],
          access: %{"infra" => :read_only}
        },
        snapshot.installation.revision,
        @actor
      )

    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    assert Enum.all?(rows(), &(not Map.has_key?(&1, "access")))

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    assert Enum.map(rows(), &{&1["repository_ref"], &1["position"], &1["access"]}) == [
             {"docs", 0, "read_write"},
             {"api", 1, "read_write"},
             {"infra", 2, "read_write"}
           ]

    # The default repository is the one a task changes, so the database
    # refuses it read only whatever writes it.
    assert_raise Postgrex.Error, ~r/environment_repository_settings_access_valid/, fn ->
      Repo.transaction(fn ->
        SQL.query!(
          Repo,
          "UPDATE environment_repository_settings SET access = 'read_only' WHERE position = 0",
          []
        )
      end)
    end
  end

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration do
    unless Code.ensure_loaded?(@migration) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", @file_name))
      |> Code.compile_file()
    end

    @migration
  end

  # Read without the schema, so the rolled-back table can be read at all.
  defp rows do
    %{columns: columns, rows: rows} =
      SQL.query!(
        Repo,
        "SELECT * FROM environment_repository_settings WHERE environment_ref = 'production' " <>
          "ORDER BY position",
        []
      )

    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
