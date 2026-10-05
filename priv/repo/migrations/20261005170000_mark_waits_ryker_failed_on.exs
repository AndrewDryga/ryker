defmodule Ryker.Repo.Migrations.MarkWaitsRykerFailedOn do
  use Ecto.Migration

  # A wait Ryker fails to schedule or resume is marked and passed over, then tried again ten
  # minutes on: the earliest due wait was taken again on every poll, and one that kept failing
  # held up every other (2026-10-04 review).
  @codes ~w(deadline poll_after timer_deadline source_kind cursor)
  @failures ~w(schedule_failed resume_failed)

  def up, do: allow(@codes ++ @failures)

  # The older check refuses the marks, and an unmarked wait is tried on every poll again.
  def down do
    execute("UPDATE #{table()} SET wait_error = NULL WHERE wait_error IN #{list(@failures)}")
    allow(@codes)
  end

  defp allow(codes) do
    execute("ALTER TABLE #{table()} DROP CONSTRAINT episode_state_record_wait_error_valid")

    execute("""
    ALTER TABLE #{table()}
      ADD CONSTRAINT episode_state_record_wait_error_valid CHECK (
        wait_error IS NULL OR (kind = 'event_wait' AND wait_error IN #{list(codes)})
      )
    """)
  end

  defp list(codes), do: "(" <> Enum.map_join(codes, ", ", &"'#{&1}'") <> ")"

  defp table do
    schema = String.replace(prefix() || "public", "\"", "\"\"")
    ~s("#{schema}".episode_state_records)
  end
end
