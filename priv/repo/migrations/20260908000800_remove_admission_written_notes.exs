defmodule Responder.Repo.Migrations.RemoveAdmissionWrittenNotes do
  use Ecto.Migration

  def up do
    # Clean pre-v1 removal of the model-written notes layer, under the same
    # authorized derived-memory reset as NormalizeKnowledgeSources. Keep every
    # source receipt, original Inbox message, and session disclosure fence.
    execute("""
    UPDATE #{table_name("conversation_observations")}
    SET note = NULL, source_result_ref = NULL
    WHERE note IS NOT NULL AND
      (source_result_ref IS NULL OR source_result_ref NOT LIKE 'input:%')
    """)
  end

  def down, do: raise("restore the qualified database backup to recover reset derived notes")
  defp table_name(name), do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{name}")
end
