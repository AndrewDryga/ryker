defmodule Ryker.Repo.Migrations.AddExplicitKnowledgeRebuilds do
  use Ecto.Migration

  def change do
    alter table(:conversation_learning_batches) do
      add(:rebuild_target_id, references(:conversation_knowledge, type: :uuid))
      add(:rebuild_target_version, :bigint)
      add(:rebuild_target_generation, :bigint)
      add(:rebuild_selection, :text)
    end

    create(
      unique_index(
        :conversation_learning_batches,
        [:rebuild_target_id, :rebuild_target_generation],
        where: "rebuild_target_id IS NOT NULL",
        name: :learning_one_rebuild_generation
      )
    )

    create(
      constraint(:conversation_learning_batches, :learning_rebuild_target_valid,
        check:
          "(rebuild_target_id IS NULL AND rebuild_target_version IS NULL AND rebuild_target_generation IS NULL AND rebuild_selection IS NULL) OR " <>
            "(rebuild_target_id IS NOT NULL AND rebuild_target_version IS NOT NULL AND rebuild_target_version > 0 " <>
            "AND rebuild_target_generation IS NOT NULL AND rebuild_target_generation > 0 AND rebuild_selection IS NOT NULL)"
      )
    )

    alter table(:conversation_learning_runs) do
      add(:rebuild, :text)
      add(:batch_budget_version, :integer, null: false, default: 0)
    end
  end
end
