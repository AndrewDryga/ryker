defmodule Ryker.Repo.Migrations.ReserveSlackTaskCardFirstWrite do
  use Ecto.Migration

  def up do
    alter table(:slack_task_cards) do
      add(:first_write_started_at, :utc_datetime_usec)
    end

    # Older claimed cards have no separate record of when Slack received a post.
    execute("""
    UPDATE slack_task_cards SET first_write_started_at = updated_at
    WHERE message_ref IS NULL AND (lease_ref IS NOT NULL OR attempt_count > 0)
    """)
  end
end
