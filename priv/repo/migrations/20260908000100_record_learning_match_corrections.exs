defmodule Ryker.Repo.Migrations.RecordLearningMatchCorrections do
  use Ecto.Migration

  def change do
    alter table(:conversation_learning_runs) do
      add(:match_refs, :text, null: false, default: "[]")
    end
  end
end
