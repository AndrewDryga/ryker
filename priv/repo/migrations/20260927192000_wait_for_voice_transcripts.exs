defmodule Ryker.Repo.Migrations.WaitForVoiceTranscripts do
  use Ecto.Migration

  # Andrew, 2026-09-27: a Slack voice message was transcribed inside the Slack
  # gateway before its envelope was acknowledged. A clip longer than about
  # 25 s made Slack deliver it again, and every later event waited behind it.
  # A voice message is now recorded first with its transcript pending, and
  # `awaiting_transcript_until` keeps routing off it until the words are
  # filled in, or until that time passes. Its queue history says which:
  # `transcribed` or `transcript_timed_out`.
  #
  # Rolling back refuses while a message waits for its words, which the
  # previous release would route without, or while a queue history holds a
  # transcript step, which the previous release can neither read nor keep.

  @kinds ~w(saved waiting_predecessor claimed reclaimed retry_scheduled blocked rearmed superseded)
  @transcript_kinds ~w(transcribed transcript_timed_out)

  def up do
    alter table(:ingress_inbox_entries) do
      add(:awaiting_transcript_until, :utc_datetime_usec)
    end

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_transcript_wait_valid,
        check: "awaiting_transcript_until IS NULL OR status = 'pending'"
      )
    )

    drop(constraint(:input_custody_transitions, :input_custody_transition_valid))

    create(
      constraint(:input_custody_transitions, :input_custody_transition_valid,
        check: transition(@kinds ++ @transcript_kinds)
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("ingress_inbox_entries")}
        WHERE awaiting_transcript_until IS NOT NULL
      ) OR EXISTS (
        SELECT 1 FROM #{qualified("input_custody_transitions")}
        WHERE kind IN (#{quoted(@transcript_kinds)})
      ) THEN
        RAISE EXCEPTION 'voice messages wait for their transcripts here; the previous release cannot keep that';
      END IF;
    END
    $$
    """)

    drop(constraint(:input_custody_transitions, :input_custody_transition_valid))

    create(
      constraint(:input_custody_transitions, :input_custody_transition_valid,
        check: transition(@kinds)
      )
    )

    drop(constraint(:ingress_inbox_entries, :ingress_inbox_transcript_wait_valid))

    alter table(:ingress_inbox_entries) do
      remove(:awaiting_transcript_until)
    end
  end

  defp transition(kinds) do
    """
    sequence > 0 AND generation > 0 AND attempt >= 0 AND
    kind IN (#{quoted(kinds)}) AND
    (owner_ref IS NULL OR char_length(owner_ref) BETWEEN 1 AND 1024) AND
    (error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 128) AND
    (detail IS NULL OR char_length(detail) BETWEEN 1 AND 4096) AND
    (predecessor_input_id IS NULL OR kind = 'waiting_predecessor') AND
    (kind = 'superseded' OR superseding_input_id IS NULL)
    """
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
