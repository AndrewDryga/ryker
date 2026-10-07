defmodule Ryker.WorkExamples.ConfirmedTaskMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.TestMigrations

  @version 20_261_007_190_000
  @at ~N[2026-10-01 12:00:00]
  @identity String.duplicate("a", 64)
  @key "slack-message:slack:T1:C1:1787832001.000100"
  @conversation "slack:T1:C1"

  # A task confirmed from a card started a request no message asked, so its
  # Work example named no message and forgetting the one the task was offered
  # in never reached it (2026-10-04 review; 32 of 47 live examples of
  # confirmed tasks on 2026-10-07). The examples already kept take what the
  # source request's own examples name, and one whose source a person already
  # made Ryker forget is erased as that forget would have.
  test "a confirmed task's example names its source request's messages, and goes with a forgotten one" do
    in_scratch_schema("confirmed_tasks", fn repo, prefix ->
      migrate!(repo, prefix, TestMigrations.version_before(@version))

      source = episode!(repo, prefix, nil)
      routing_example!(repo, prefix, source, nil)
      task = episode!(repo, prefix, source)
      kept = work_example!(repo, prefix, task)

      forgotten_source = episode!(repo, prefix, nil)
      routing_example!(repo, prefix, forgotten_source, @at)
      forgotten_task = episode!(repo, prefix, forgotten_source)
      erased = work_example!(repo, prefix, forgotten_task)
      feedback!(repo, prefix, erased)

      assert @version in migrate!(repo, prefix, @version)

      assert [[[@identity], [@key], [@conversation], nil]] = traced(repo, prefix, kept)

      assert [[[@identity], [@key], [@conversation], %NaiveDateTime{}]] =
               traced(repo, prefix, erased)

      assert %{rows: [[nil, nil]]} = bodies(repo, prefix, erased)

      assert %{rows: [[0]]} =
               SQL.query!(repo, "SELECT count(*) FROM #{prefix}.work_example_feedback", [])
    end)
  end

  defp episode!(repo, prefix, linked) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_kernel_episodes
        (id, key, state, destination_transport, destination_conversation_ref, linked_episode_id,
         inserted_at, updated_at)
      VALUES ($1, $2, 'complete', 'slack', $3, $4, $5, $5)
      """,
      [
        Ecto.UUID.dump!(id),
        "episode:#{id}",
        @conversation,
        linked && Ecto.UUID.dump!(linked),
        @at
      ]
    )

    id
  end

  # The routing example of the message the source request was asked in.
  defp routing_example!(repo, prefix, episode, nil) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.routing_examples
        (id, input_id, episode_id, source_identity, message_keys, conversation_refs, transport,
         conversation_ref, execution_mode, policy, policy_digest, prompt, output_schema, answer,
         decision, outcome, usage, rejected_answers, decided_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, 'slack', $7, 'live', 'routing', $4, 'p', '{}', 'a', '{}',
        '{}', '{}', '[]', $8, $8, $8)
      """,
      [
        uuid(),
        uuid(),
        Ecto.UUID.dump!(episode),
        @identity,
        [@key],
        [@conversation],
        @conversation,
        @at
      ]
    )
  end

  defp routing_example!(repo, prefix, episode, forgotten_at) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.routing_examples
        (id, input_id, episode_id, source_identity, message_keys, conversation_refs, transport,
         conversation_ref, execution_mode, policy, policy_digest, decided_at, forgotten_at,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, 'slack', $7, 'live', 'routing', $4, $8, $9, $8, $8)
      """,
      [
        uuid(),
        uuid(),
        Ecto.UUID.dump!(episode),
        @identity,
        [@key],
        [@conversation],
        @conversation,
        @at,
        forgotten_at
      ]
    )
  end

  # A kept example of the confirmed task's turn, naming no message.
  defp work_example!(repo, prefix, episode) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.work_examples
        (id, turn_id, episode_id, episode_ref, conversation_refs, execution_mode, briefing,
         context, output_schema, trajectory, result, rejected_results, outcome, usage, settled_at,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, 'live', 'b', '{}', '{}', '[]', 'r', '[]', '{}', '{}', $6, $6, $6)
      """,
      [Ecto.UUID.dump!(id), uuid(), Ecto.UUID.dump!(episode), "task", [@conversation], @at]
    )

    id
  end

  defp feedback!(repo, prefix, example) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.work_example_feedback
        (id, example_id, signal_id, kind, category, occurred_at)
      VALUES ($1, $2, $3, 'reaction', 'negative', $4)
      """,
      [uuid(), Ecto.UUID.dump!(example), uuid(), @at]
    )
  end

  defp traced(repo, prefix, example) do
    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT source_identities, message_keys, conversation_refs, forgotten_at " <>
          "FROM #{prefix}.work_examples WHERE id = $1",
        [Ecto.UUID.dump!(example)]
      )

    rows
  end

  defp bodies(repo, prefix, example) do
    SQL.query!(
      repo,
      "SELECT briefing, result FROM #{prefix}.work_examples WHERE id = $1",
      [Ecto.UUID.dump!(example)]
    )
  end

  defp uuid, do: Ecto.UUID.dump!(Ecto.UUID.generate())
end
