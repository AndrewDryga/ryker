defmodule Ryker.Feedback.MessageRefMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @before_version 20_260_927_192_000
  @version 20_260_927_193_000
  @at ~N[2026-09-27 09:00:00.000000]

  # A reaction's feedback names the message it was on since Chat's quick
  # replies and updates took reactions (2026-09-27). The reactions people gave
  # Work replies before that are the feedback a model will later learn from:
  # each must come through naming the message its request's event recorded,
  # and a backfill that wrote a message onto any other signal would stop the
  # deploy at its own constraint. Rolling back keeps every signal.
  test "a reaction kept before messages were named gets its request's message, and nothing else does" do
    in_scratch_schema("feedback_message_ref", fn repo, prefix ->
      migrate!(repo, prefix, @before_version)

      episode_id = episode!(repo, prefix)
      reaction_event!(repo, prefix, episode_id, "slack-reaction:on-reply", "1711.000100")

      on_reply = feedback!(repo, prefix, episode_id, "reaction_added", "slack-reaction:on-reply")
      # An update's reaction has no event of its request to name the message.
      on_update =
        feedback!(repo, prefix, episode_id, "reaction_added", "slack-reaction:on-update")

      # The same event is never a reaction on a signal of another kind.
      edited = feedback!(repo, prefix, episode_id, "message_edited", "slack-reaction:on-reply")

      assert @version in migrate!(repo, prefix, @version)

      assert message_refs(repo, prefix) == %{
               on_reply => "1711.000100",
               on_update => nil,
               edited => nil
             }

      assert_raise Postgrex.Error, ~r/answer_feedback_message_ref_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.answer_feedback SET message_ref = 'x' WHERE id = $1",
          [Ecto.UUID.dump!(edited)]
        )
      end

      assert rollback!(repo, prefix) ==
               [@version]

      %{rows: [[kept]]} =
        SQL.query!(repo, "SELECT count(*) FROM #{prefix}.answer_feedback", [])

      assert kept == 3
    end)
  end

  defp episode!(repo, prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_kernel_episodes
        (id, key, state, destination_transport, destination_conversation_ref,
         inserted_at, updated_at)
      VALUES ($1, $2, 'complete', 'slack', 'T1:C1', $3, $3)
      """,
      [Ecto.UUID.dump!(id), "episode:#{id}", @at]
    )

    id
  end

  defp reaction_event!(repo, prefix, episode_id, event_ref, message_ref) do
    payload =
      Jason.encode!(%{
        "action" => "add",
        "event_ref" => event_ref,
        "kind" => "record_reaction",
        "target_delivery_ref" => "delivery:reply",
        "target_message_ref" => message_ref
      })

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_kernel_events
        (id, episode_id, sequence, kind, dedupe_key, fingerprint, payload,
         occurred_at, inserted_at)
      VALUES ($1, $2, 1, 'reaction_recorded', $3, $4, $5, $6, $6)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(episode_id),
        event_ref,
        String.duplicate("a", 64),
        payload,
        @at
      ]
    )
  end

  defp feedback!(repo, prefix, episode_id, kind, source_ref) do
    id = Ecto.UUID.generate()

    {value, category} =
      if kind == "reaction_added", do: {"+1", "satisfied"}, else: {nil, "edited"}

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.answer_feedback
        (id, kind, value, category, actor_ref, source, source_ref, occurred_at, episode_id)
      VALUES ($1, $2, $3, $4, 'U1', 'slack', $5, $6, $7)
      """,
      [
        Ecto.UUID.dump!(id),
        kind,
        value,
        category,
        source_ref,
        @at,
        Ecto.UUID.dump!(episode_id)
      ]
    )

    id
  end

  defp message_refs(repo, prefix) do
    %{rows: rows} =
      SQL.query!(repo, "SELECT id, message_ref FROM #{prefix}.answer_feedback", [])

    Map.new(rows, fn [id, message_ref] -> {Ecto.UUID.load!(id), message_ref} end)
  end
end
