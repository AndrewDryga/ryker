defmodule Ryker.Repo.Migrations.RecordRepositoryKnowledgeSent do
  use Ecto.Migration

  # A proposal can fail after it writes RYKER.md on Ryker's branch and
  # before it records what it proposed (review of the knowledge lane,
  # 2026-09-28). The next proposal compared the branch only with the last one
  # recorded, so after a refresh it read Ryker's own words there as a
  # person's edit, and left the pull request alone for good.
  #
  # `sent_sha256s` holds the sha256 of each document Ryker was about to write
  # there since it last recorded a proposal, each recorded before it is
  # written (`Ryker.RepositoryKnowledge.Custody.sending/1`): a branch that
  # holds one of them is Ryker's own. Every entry starts with none, since
  # what each last proposed is still Work's copy. Rolling back forgets only
  # what was sent.

  def change do
    alter table(:repository_knowledge) do
      add(:sent_sha256s, {:array, :text}, null: false, default: [])
    end

    create(
      constraint(:repository_knowledge, :repository_knowledge_sent_valid,
        check: "array_to_string(sent_sha256s, ',', '-') ~ '^([0-9a-f]{64}(,[0-9a-f]{64})*)?$'"
      )
    )
  end
end
