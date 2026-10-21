defmodule Ryker.Repo.Migrations.RecordGuidanceResults do
  use Ecto.Migration

  @kinds ~w(task_offer publication_offer schedule_offer memory_offer preference_offer guidance_offer
    standing_assignment_offer slack_post_offer input_request event_wait emisar_approval evidence
    coverage finding progress goal goal_state alert_assessment automation_change_offer)

  def up, do: allow(@kinds ++ ["guidance_result"])

  def down do
    # A rollback cannot erase the evidence of whether a correction worked.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{table()} WHERE kind = 'guidance_result') THEN
        RAISE EXCEPTION 'guidance results exist; rollback would strand retained history';
      END IF;
    END $$;
    """)

    allow(@kinds)
  end

  defp allow(kinds) do
    execute("ALTER TABLE #{table()} DROP CONSTRAINT episode_state_record_identity_valid")

    execute("""
    ALTER TABLE #{table()} ADD CONSTRAINT episode_state_record_identity_valid CHECK (
      char_length(ref) BETWEEN 1 AND 256 AND char_length(operation_id) BETWEEN 1 AND 80
      AND kind IN (#{Enum.map_join(kinds, ", ", &"'#{&1}'")})
      AND status IN ('open', 'confirmed', 'answered', 'dismissed', 'superseded')
      AND char_length(payload_fingerprint) = 64
      AND ((kind IN ('goal', 'goal_state') AND char_length(subject_ref) BETWEEN 1 AND 120)
        OR (kind NOT IN ('goal', 'goal_state') AND subject_ref IS NULL))
    )
    """)
  end

  defp table,
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".episode_state_records)
end
