defmodule Ryker.Repo.Migrations.AllowTaskReviewsWithoutSourceMessages do
  use Ecto.Migration

  def up do
    # A standing rule can start a task from a webhook routed to a channel,
    # before any Slack message exists. Its confirmed task grant authorizes
    # review; requiring a message stranded completion or invented provenance.
    execute("ALTER TABLE episode_publications ALTER COLUMN offer_message_ref DROP NOT NULL")
  end

  def down do
    # Refuse if message-free reviews exist; production rollback restores the backup.
    execute("ALTER TABLE episode_publications ALTER COLUMN offer_message_ref SET NOT NULL")
  end
end
