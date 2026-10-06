defmodule Ryker.Repo.Migrations.IndexSlackReplyLookups do
  use Ecto.Migration

  # Repainting a Slack reply found its turn by reading every delivered turn's
  # receipt as JSON, and every ambient threaded message asked the routing
  # responses for its thread with no index to read (2026-10-04 review).

  def up do
    execute("""
    CREATE INDEX episode_work_turns_receipt_message ON episode_work_turns
      (((external_receipt::jsonb) ->> 'message_ref'))
      WHERE external_receipt IS NOT NULL
    """)

    create(
      index(:delivery_routing_responses, [:transport, :conversation_ref, :thread_ref],
        name: :delivery_routing_responses_thread
      )
    )
  end

  def down do
    drop(
      index(:delivery_routing_responses, [:transport, :conversation_ref, :thread_ref],
        name: :delivery_routing_responses_thread
      )
    )

    execute("DROP INDEX episode_work_turns_receipt_message")
  end
end
