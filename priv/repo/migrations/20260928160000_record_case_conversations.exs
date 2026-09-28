defmodule Ryker.Repo.Migrations.RecordCaseConversations do
  use Ecto.Migration

  # Deleting a Slack channel withdraws every case built from its messages
  # (2026-09-28), as it erases the routing examples that quoted them
  # (`Ryker.Memories.Cases`). A case names the conversation its work lived in,
  # and work can gather messages from other conversations too, so a case now
  # records every conversation its messages came from, and a deletion finds it
  # by an index.
  #
  # A case kept before this learns the conversations of its messages that
  # Ryker still holds, found by the message identities it keeps. A message
  # that has already expired names no conversation, so such a case is found
  # only by the conversation its work lived in.
  #
  # Rolling back forgets only the conversations.

  def up do
    alter table(:episode_case_records) do
      add(:conversation_refs, {:array, :text}, null: false, default: [])
    end

    execute("""
    WITH conversations AS (
      SELECT DISTINCT record.id, message.destination_conversation_ref AS conversation_ref
      FROM #{qualified("episode_case_records")} AS record
      CROSS JOIN LATERAL unnest(record.source_refs) AS source(native_input_id)
      JOIN #{qualified("ingress_inbox_entries")} AS message
        ON message.native_input_id = source.native_input_id
    )
    UPDATE #{qualified("episode_case_records")} AS record
    SET conversation_refs = ARRAY(
      SELECT conversations.conversation_ref
      FROM conversations
      WHERE conversations.id = record.id
      ORDER BY conversations.conversation_ref
      LIMIT 64
    )
    WHERE record.id IN (SELECT conversations.id FROM conversations)
    """)

    create(
      constraint(:episode_case_records, :episode_case_record_conversations_valid,
        check: "cardinality(conversation_refs) <= 64"
      )
    )

    create(index(:episode_case_records, [:conversation_refs], using: :gin))
  end

  def down do
    drop(index(:episode_case_records, [:conversation_refs]))
    drop(constraint(:episode_case_records, :episode_case_record_conversations_valid))

    alter table(:episode_case_records) do
      remove(:conversation_refs)
    end
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
