defmodule Ryker.Repo.Migrations.LetRelearnedTopicsBeDeleted do
  use Ecto.Migration

  # A relearn batch named its topic through the one foreign key to topics with
  # no ON DELETE, so deleting a channel that had a relearned topic rolled back,
  # and every topic, note and person fact of that channel stayed recallable
  # (found 2026-10-04). A batch whose topic is gone already reads as having
  # nothing to relearn (`Ryker.Learning.Rebuilds.inputs/1`), so the key goes.

  def up do
    execute("""
    ALTER TABLE #{qualified("conversation_learning_batches")}
      DROP CONSTRAINT conversation_learning_batches_rebuild_target_id_fkey
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{qualified("conversation_learning_batches")}
      ADD CONSTRAINT conversation_learning_batches_rebuild_target_id_fkey
      FOREIGN KEY (rebuild_target_id) REFERENCES #{qualified("conversation_knowledge")}(id)
    """)
  end

  defp qualified(name) do
    schema = String.replace(prefix() || "public", "\"", "\"\"")
    ~s("#{schema}".#{name})
  end
end
