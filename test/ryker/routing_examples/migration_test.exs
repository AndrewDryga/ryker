defmodule Ryker.RoutingExamples.MigrationTest do
  @moduledoc """
  Keeping routing examples for training adds two retention settings to the
  row every installation already has and a table of its own. The saved
  limits must survive both ways, keeping them must start off, and rolling
  back must refuse while any example is kept rather than drop them.
  """
  use Ryker.MigrationCase

  alias Ecto.Adapters.SQL

  @before_version 20_260_927_160_000
  @version 20_260_927_180_000
  @at ~N[2026-09-27 09:00:00.000000]
  @day 86_400

  test "saved limits survive, keeping examples starts off, and a kept example blocks rollback" do
    in_scratch_schema("routing_examples", fn repo, prefix ->
      migrate!(repo, prefix, @before_version)

      installation!(repo, prefix)

      assert @version in migrate!(repo, prefix, @version)

      # The saved limits are kept, and keeping examples starts off, for a year.
      assert retention(repo, prefix) == [60 * @day, 30 * @day, false, 365 * @day]

      # A kept example holds every body, a forgotten one none.
      assert_raise Postgrex.Error, ~r/routing_example_bodies_valid/, fn ->
        example!(repo, prefix, "NULL", "'{}'")
      end

      example!(repo, prefix, "$2", "NULL")

      assert_raise Postgrex.Error, ~r/routing examples are kept for training/, fn ->
        rollback!(repo, prefix)
      end

      assert count(repo, prefix) == 1

      SQL.query!(repo, "DELETE FROM #{prefix}.routing_examples", [])

      assert rollback!(repo, prefix) ==
               [@version]

      %{rows: [[audit, operational]]} =
        SQL.query!(
          repo,
          "SELECT audit_data_seconds, operational_data_seconds FROM #{prefix}.retention_settings",
          []
        )

      assert {audit, operational} == {60 * @day, 30 * @day}
    end)
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
end
