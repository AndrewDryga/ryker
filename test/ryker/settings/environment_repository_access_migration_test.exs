defmodule Ryker.Settings.EnvironmentRepositoryAccessMigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_260_927_151_500
  @actor "control-plane:local"

  # Andrew, 2026-09-27: "can we here limit read or read/write access per
  # repo?" Until then a task could change any repository of its environment,
  # so an environment saved before the choice existed has to keep working as
  # it did: every repository it holds arrives read and write, in the order it
  # had. Nothing may arrive read only, which would quietly stop work there
  # from changing code it changed the day before.
  #
  # The repositories are written after the rollback, in the shape they had
  # before access existed; written before it, they carried an access the
  # rollback threw away, and the test read as if it asserted that loss
  # (2026-10-04 review).
  test "an environment saved before access existed keeps every repository read and write" do
    {:ok, snapshot} = Settings.initialize(@actor)

    snapshot =
      Enum.reduce(~w(api docs infra), snapshot, fn ref, current ->
        {:ok, saved} = Settings.put_repository(%{ref: ref}, current.installation.revision, @actor)
        saved
      end)

    {:ok, _saved} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: ["docs"]},
        snapshot.installation.revision,
        @actor
      )

    assert migrate_down(@version) == :ok
    assert Enum.all?(rows(), &(not Map.has_key?(&1, "access")))

    SQL.query!(
      Repo,
      "INSERT INTO environment_repository_settings (environment_ref, repository_ref, position) " <>
        "VALUES ('production', 'api', 1), ('production', 'infra', 2)",
      []
    )

    assert migrate_up(@version) == :ok

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
