defmodule Ryker.Repo.Migrations.BindDeliveryTargets do
  use Ecto.Migration

  # An accepted answer keeps the exact destination it was accepted with, so a
  # question asked in a new thread is answered there while the episode's
  # progress home stays where the work started. Without the frozen target every
  # reply was derived from the home, and a colleague who asked elsewhere was
  # answered somewhere they were not reading.
  def up do
    alter table(:episode_work_turns) do
      add(:delivery_target, :text)
    end
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_work_turns")} WHERE delivery_target IS NOT NULL LIMIT 1
      ) THEN
        RAISE EXCEPTION 'accepted deliveries have bound targets and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    alter table(:episode_work_turns) do
      remove(:delivery_target)
    end
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
