defmodule Ryker.WorkExamples.MigrationTest do
  @moduledoc """
  Keeping work examples for training adds two retention settings to the row
  every installation already has and two tables of their own. The saved
  limits and the routing example setting must survive both ways, keeping work
  examples must start off, and rolling back must refuse while any example is
  kept rather than drop them.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @before_version 20_260_930_110_000
  @version 20_261_002_120_000
  @at ~N[2026-10-02 09:00:00.000000]
  @day 86_400

  test "saved limits survive, keeping work examples starts off, and a kept example blocks rollback" do
    repo = start_migration_repo!()
    prefix = "work_examples_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
        to: @before_version,
        prefix: prefix,
        log: false
      )

      installation!(repo, prefix)

      assert @version in Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
               to: @version,
               prefix: prefix,
               log: false
             )

      # The saved limits and routing setting are kept; work examples start off, for a year.
      assert retention(repo, prefix) == [60 * @day, true, false, 365 * @day]

      # A kept example holds every body, a forgotten one none.
      assert_raise Postgrex.Error, ~r/work_example_bodies_valid/, fn ->
        example!(repo, prefix, "NULL", "NULL")
      end

      example!(repo, prefix, "$2", "NULL")

      assert_raise Postgrex.Error, ~r/work examples are kept for training/, fn ->
        Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      SQL.query!(repo, "DELETE FROM #{prefix}.work_examples", [])

      assert Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
               step: 1,
               prefix: prefix,
               log: false
             ) ==
               [@version]

      %{rows: [[audit, routing]]} =
        SQL.query!(
          repo,
          "SELECT audit_data_seconds, routing_examples_enabled FROM #{prefix}.retention_settings",
          []
        )

      assert {audit, routing} == {60 * @day, true}
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp installation!(repo, prefix) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.installation_settings
        (host_ref, revision, saved_by, saved_at, inserted_at)
      VALUES ('installation:migration', 2, 'control-plane:local', $1, $1)
      """,
      [@at]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.retention_settings
        (id, operational_data_seconds, conversation_memory_seconds, closed_work_seconds,
         episode_history_seconds, audit_data_seconds, routing_examples_enabled)
      VALUES ('installation:migration', $1, $2, $1, $1, $3, true)
      """,
      [30 * @day, 90 * @day, 60 * @day]
    )
  end

  defp retention(repo, prefix) do
    %{rows: [row]} =
      SQL.query!(
        repo,
        """
        SELECT audit_data_seconds, routing_examples_enabled, work_examples_enabled,
               work_examples_seconds
        FROM #{prefix}.retention_settings
        """,
        []
      )

    row
  end

  # A forgotten example when `forgotten_at` is set and its bodies NULL; one
  # with neither bodies nor forgetting is refused.
  defp example!(repo, prefix, forgotten_at, briefing) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.work_examples
        (id, turn_id, episode_id, episode_ref, execution_mode, briefing, settled_at,
         forgotten_at, inserted_at, updated_at)
      VALUES ($1, $1, $1, 'episode:migration', 'live', #{briefing}, $2, #{forgotten_at}, $2, $2)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), @at]
    )
  end

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
