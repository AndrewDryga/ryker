defmodule Ryker.RoutingExamples.MigrationTest do
  @moduledoc """
  Keeping routing examples for training adds two retention settings to the
  row every installation already has and a table of its own. The saved
  limits must survive both ways, keeping them must start off, and rolling
  back must refuse while any example is kept rather than drop them.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @before_version 20_260_927_160_000
  @version 20_260_927_170_000
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @at ~N[2026-09-27 09:00:00.000000]
  @day 86_400

  test "saved limits survive, keeping examples starts off, and a kept example blocks rollback" do
    repo = start_migration_repo!()
    prefix = "routing_examples_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @before_version,
        prefix: prefix,
        log: false
      )

      installation!(repo, prefix)

      assert @version in Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @version,
               prefix: prefix,
               log: false
             )

      # The saved limits are kept, and keeping examples starts off, for a year.
      assert retention(repo, prefix) == [60 * @day, 30 * @day, false, 365 * @day]

      # A kept example holds every body, a forgotten one none.
      assert_raise Postgrex.Error, ~r/routing_example_bodies_valid/, fn ->
        example!(repo, prefix, "NULL", "'{}'")
      end

      example!(repo, prefix, "$2", "NULL")

      assert_raise Postgrex.Error, ~r/routing examples are kept for training/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
      end

      assert count(repo, prefix) == 1

      SQL.query!(repo, "DELETE FROM #{prefix}.routing_examples", [])

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@version]

      %{rows: [[audit, operational]]} =
        SQL.query!(
          repo,
          "SELECT audit_data_seconds, operational_data_seconds FROM #{prefix}.retention_settings",
          []
        )

      assert {audit, operational} == {60 * @day, 30 * @day}
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
         episode_history_seconds, audit_data_seconds)
      VALUES ('installation:migration', $1, $2, $1, $1, $3)
      """,
      [30 * @day, 90 * @day, 60 * @day]
    )
  end

  defp retention(repo, prefix) do
    %{rows: [row]} =
      SQL.query!(
        repo,
        """
        SELECT audit_data_seconds, operational_data_seconds, routing_examples_enabled,
               routing_examples_seconds
        FROM #{prefix}.retention_settings
        """,
        []
      )

    row
  end

  # A forgotten example when `forgotten_at` is set and `prompt` NULL; a
  # half-forgotten one otherwise, which the table refuses.
  defp example!(repo, prefix, forgotten_at, prompt) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.routing_examples
        (id, input_id, source_identity, transport, conversation_ref, execution_mode, policy,
         policy_digest, prompt, decided_at, forgotten_at, inserted_at, updated_at)
      VALUES ($1, $1, repeat('a', 64), 'slack', 'slack:T1:C1', 'live', 'ryker-admission',
              repeat('b', 64), #{prompt}, $2, #{forgotten_at}, $2, $2)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), @at]
    )
  end

  defp count(repo, prefix) do
    %{rows: [[count]]} = SQL.query!(repo, "SELECT count(*) FROM #{prefix}.routing_examples", [])
    count
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
