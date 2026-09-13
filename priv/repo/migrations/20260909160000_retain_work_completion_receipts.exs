defmodule Ryker.Repo.Migrations.RetainWorkCompletionReceipts do
  use Ecto.Migration

  def change do
    alter table(:episode_work_turns) do
      add(:completion_receipt, :text)
    end

    create(
      constraint(:episode_work_turns, :episode_work_turn_completion_receipt_valid,
        check:
          "completion_receipt IS NULL OR (coop_turn_id IS NOT NULL AND candidate_sha256 IS NOT NULL AND validation_intent IS NOT NULL)"
      )
    )
  end
end
