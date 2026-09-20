defmodule Ryker.Repo.Migrations.RetainRepositoryKnowledge do
  use Ecto.Migration

  def change do
    alter table(:repository_settings) do
      add(:knowledge_content, :text)
      add(:knowledge_status, :text)
      add(:knowledge_source_commit, :text)
      add(:knowledge_sha256, :text)
    end

    create(
      constraint(:repository_settings, :repository_knowledge_valid,
        check:
          "(knowledge_status IS NULL AND knowledge_content IS NULL AND knowledge_source_commit IS NULL AND knowledge_sha256 IS NULL) OR " <>
            "(knowledge_status IN ('accepted', 'proposed') AND knowledge_content IS NOT NULL AND " <>
            "knowledge_source_commit ~ '^[0-9a-f]{40}$' AND knowledge_sha256 ~ '^[0-9a-f]{64}$')"
      )
    )
  end
end
