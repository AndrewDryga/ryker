defmodule Ryker.Repo.Migrations.ABackgroundSessionKeepsWhatItsWorkerSent do
  use Ecto.Migration

  # Retained activity had exactly one owner, an episode or a routed message, so
  # a learning, self-analysis or repository-reading session's activity was
  # acknowledged and dropped. Its worker's record of each prompt it sent
  # (`prompt.sent`) is what that run's card shows as sent to the model, so a
  # session with no owner now keeps those records, and only those; they leave
  # with the session (`Ryker.Retention.Data`).

  @owned "(episode_id IS NOT NULL) <> (admission_input_id IS NOT NULL)"
  @sent "kind = 'prompt.sent' AND episode_id IS NULL AND admission_input_id IS NULL"

  def up do
    drop(constraint(:episode_work_activity, :activity_owner_valid))

    create(
      constraint(:episode_work_activity, :activity_owner_valid,
        check: "(#{@owned}) OR (#{@sent})"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_work_activity")}
        WHERE episode_id IS NULL AND admission_input_id IS NULL
      ) THEN
        RAISE EXCEPTION 'Background sessions still keep what their workers sent; remove those records before rolling back';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_work_activity, :activity_owner_valid))
    create(constraint(:episode_work_activity, :activity_owner_valid, check: @owned))
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> "#{prefix}.#{table}"
    end
  end
end
