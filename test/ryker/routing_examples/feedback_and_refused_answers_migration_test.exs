defmodule Ryker.RoutingExamples.FeedbackAndRefusedAnswersMigrationTest do
  @moduledoc """
  Keeping feedback and refused answers with routing examples adds a column to
  the examples every installation that keeps them already has, and a table
  beside them. A kept example must gain an empty list of refused answers and
  a forgotten one none; a copy of feedback leaves with its example; and
  rolling back must refuse while an example keeps either, rather than drop
  what was kept on purpose.
  """
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @before_version 20_260_930_020_000
  @version 20_260_930_060_000
  @at ~N[2026-09-30 06:00:00.000000]

  test "kept examples gain no refused answers, feedback copies leave with their example, and either blocks rollback" do
    in_scratch_schema("routing_feedback", fn repo, prefix ->
      migrate!(repo, prefix, @before_version)

      kept = kept_example!(repo, prefix)
      forgotten = forgotten_example!(repo, prefix)

      assert @version in migrate!(repo, prefix, @version)

      assert rejected_answers(repo, prefix, kept) == "[]"
      assert rejected_answers(repo, prefix, forgotten) == nil

      # A kept example holds its refused answers, a forgotten one none.
      assert_raise Postgrex.Error, ~r/routing_example_bodies_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.routing_examples SET rejected_answers = NULL WHERE id = $1",
          [kept]
        )
      end

      assert_raise Postgrex.Error, ~r/routing_example_bodies_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.routing_examples SET rejected_answers = '[]' WHERE id = $1",
          [forgotten]
        )
      end

      feedback!(repo, prefix, kept)

      assert_raise Postgrex.Error,
                   ~r/routing examples keep feedback or refused answers/,
                   fn ->
                     rollback!(repo, prefix)
                   end

      # The copy leaves with its example.
      SQL.query!(repo, "DELETE FROM #{prefix}.routing_examples WHERE id = $1", [kept])
      assert count(repo, prefix, "routing_example_feedback") == 0

      assert rollback!(repo, prefix) ==
               [@version]

      assert count(repo, prefix, "routing_examples") == 1
    end)
  end

  defp kept_example!(repo, prefix) do
    id = Ecto.UUID.dump!(Ecto.UUID.generate())

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.routing_examples
        (id, input_id, source_identity, transport, conversation_ref, execution_mode, policy,
         policy_digest, prompt, output_schema, answer, decision, outcome, usage, decided_at,
         inserted_at, updated_at)
      VALUES ($1, $1, repeat('a', 64), 'slack', 'slack:T1:C1', 'live', 'ryker-admission',
              repeat('b', 64), '{"instructions":"Decide."}', '{}', '{"action":"ignore"}',
              '{"action":"ignore"}', '{}', '{}', $2, $2, $2)
      """,
      [id, @at]
    )

    id
  end

  defp forgotten_example!(repo, prefix) do
    id = Ecto.UUID.dump!(Ecto.UUID.generate())

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.routing_examples
        (id, input_id, source_identity, transport, conversation_ref, execution_mode, policy,
         policy_digest, decided_at, forgotten_at, inserted_at, updated_at)
      VALUES ($1, $1, repeat('c', 64), 'slack', 'slack:T1:C1', 'live', 'ryker-admission',
              repeat('b', 64), $2, $2, $2, $2)
      """,
      [id, @at]
    )

    id
  end

  defp feedback!(repo, prefix, example_id) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.routing_example_feedback
        (id, example_id, signal_id, kind, value, category, occurred_at)
      VALUES (gen_random_uuid(), $1, gen_random_uuid(), 'reaction_added', '+1', 'satisfied', $2)
      """,
      [example_id, @at]
    )
  end

  defp rejected_answers(repo, prefix, id) do
    %{rows: [[value]]} =
      SQL.query!(
        repo,
        "SELECT rejected_answers FROM #{prefix}.routing_examples WHERE id = $1",
        [id]
      )

    value
  end

  defp count(repo, prefix, table) do
    %{rows: [[count]]} = SQL.query!(repo, "SELECT count(*) FROM #{prefix}.#{table}", [])
    count
  end
end
