defmodule Ryker.Repo.Migrations.IndexKnowledgeAnchors do
  use Ecto.Migration

  def change do
    alter table(:conversation_knowledge) do
      add(:anchor_keys, {:array, :text}, null: false, default: [])
    end

    create(index(:conversation_knowledge, [:anchor_keys], using: :gin))
  end
end
