defmodule Ryker.Repo.Migrations.IndexEditedMessages do
  use Ecto.Migration

  # An edit takes back the words it replaced, as a deletion takes back the
  # whole message (2026-09-28): every routing example, local routing
  # comparison and analysis of a prompt that quoted the message is erased,
  # and one not yet copied is checked for an edit of each message it quotes
  # before it is kept (`Ryker.RoutingExamples`). That check finds the edits
  # by this index, as it finds deletions by `ingress_inbox_deleted_messages`,
  # instead of reading every message of the conversation.
  #
  # Rolling back drops only the index.

  def up do
    execute("""
    CREATE INDEX ingress_inbox_edited_messages
    ON #{qualified("ingress_inbox_entries")}
    (destination_conversation_ref, (COALESCE(source_item_ref, native_input_id)))
    WHERE event_kind = 'edit'
    """)
  end

  def down do
    execute("DROP INDEX #{qualified("ingress_inbox_edited_messages")}")
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
