defmodule Ryker.Repo.Migrations.DropKnowledgeSourceNotes do
  use Ecto.Migration

  # A learned topic's source row kept a copy of its message's note, and
  # learning had stopped writing one: every direct source's note was emptied
  # before the copy, so the column was always NULL while retention and
  # forgetting still cleared it (2026-10-04 review; 37 rows, none set, on
  # 2026-10-07).

  def up do
    alter table(:conversation_knowledge_sources) do
      remove(:source_note)
    end
  end

  def down do
    alter table(:conversation_knowledge_sources) do
      add(:source_note, :text)
    end
  end
end
