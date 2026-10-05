defmodule Ryker.Ingress.WaitForVoiceTranscriptsMigrationTest do
  use Ryker.MigrationCase

  alias Ecto.Adapters.SQL

  @before_version 20_260_927_191_000
  @version 20_260_927_192_000
  @at ~N[2026-09-27 18:00:00.000000]

  # A Slack voice message is recorded before its words and routing waits for
  # them (2026-09-27). Every message and queue step an installation already
  # has keeps its values and waits for nothing; only a message routing has
  # not taken can wait; and rolling back refuses rather than route a message
  # without its words or drop a transcript step from its history.
  test "only a message routing has not taken waits for its words, and rolling back loses nothing" do
    in_scratch_schema("voice_transcripts", fn repo, prefix ->
      migrate!(repo, prefix, @before_version)

      waiting = entry!(repo, prefix, "pending")
      stopped = entry!(repo, prefix, "blocked")
      transition!(repo, prefix, waiting, 1, "saved")

      assert_raise Postgrex.Error, ~r/input_custody_transition_valid/, fn ->
        transition!(repo, prefix, waiting, 2, "transcribed")
      end

      assert @version in migrate!(repo, prefix, @version)

      assert rows(
               repo,
               "SELECT status, awaiting_transcript_until FROM #{prefix}.ingress_inbox_entries ORDER BY status DESC"
             ) ==
               [["pending", nil], ["blocked", nil]]

      wait!(repo, prefix, waiting)

      assert_raise Postgrex.Error, ~r/ingress_inbox_transcript_wait_valid/, fn ->
        wait!(repo, prefix, stopped)
      end

      # A message still waiting for its words.
      assert_raise Postgrex.Error, ~r/the previous release cannot keep that/, fn ->
        rollback!(repo, prefix)
      end

      transition!(repo, prefix, waiting, 2, "transcribed")
      transition!(repo, prefix, waiting, 3, "transcript_timed_out")

      SQL.query!(
        repo,
        "UPDATE #{prefix}.ingress_inbox_entries SET awaiting_transcript_until = NULL",
        []
      )

      # A queue history with a transcript step in it.
      assert_raise Postgrex.Error, ~r/the previous release cannot keep that/, fn ->
        rollback!(repo, prefix)
      end

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.input_custody_transitions WHERE kind <> 'saved'",
        []
      )

      assert rollback!(repo, prefix) ==
               [@version]

      assert rows(repo, "SELECT kind FROM #{prefix}.input_custody_transitions") == [["saved"]]
      assert rows(repo, "SELECT count(*) FROM #{prefix}.ingress_inbox_entries") == [[2]]
    end)
  end

  defp entry!(repo, prefix, status) do
    id = Ecto.UUID.generate()
    blocked? = status == "blocked"

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.ingress_inbox_entries
        (id, dedupe_key, event_fingerprint, source_kind, source_ref, event_ref, event_kind,
         native_input_id, actor_kind, actor_ref, destination_transport,
         destination_conversation_ref, revision, occurred_at, content, status,
         last_error_code, last_error_detail, source_capabilities, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'slack', 'T1', $2, 'message', $2, 'user', 'U1', 'slack',
              'slack:T1:D1', 1, $4, '{"text":""}', $5, $6, $7, '{}', $4, $4)
      """,
      [
        Ecto.UUID.dump!(id),
        "ingress-event:#{id}",
        String.duplicate("a", 64),
        @at,
        status,
        if(blocked?, do: "blocked"),
        if(blocked?, do: "Operator recovery required")
      ]
    )

    id
  end

  defp transition!(repo, prefix, input_id, sequence, kind) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.input_custody_transitions
        (id, input_id, sequence, kind, occurred_at, generation, attempt, inserted_at)
      VALUES ($1, $2, $3, $4, $5, 1, 0, $5)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(input_id), sequence, kind, @at]
    )
  end

  defp wait!(repo, prefix, input_id) do
    SQL.query!(
      repo,
      "UPDATE #{prefix}.ingress_inbox_entries SET awaiting_transcript_until = $1 WHERE id = $2",
      [@at, Ecto.UUID.dump!(input_id)]
    )
  end

  defp rows(repo, sql), do: SQL.query!(repo, sql, []).rows
end
