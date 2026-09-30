defmodule Ryker.Repo.Migrations.LearningReadsTheThread do
  use Ecto.Migration

  # Learning saw only the new messages of a batch. A reply that means something
  # only beside the thread it answers ("Nothing is stuck, this is done
  # manually") was deferred as impossible to place once the messages before it
  # had taught nothing on their own, and what it said was lost (the recorded
  # starfall-correction case, 2026-09-30).
  #
  # A run now also reads the earlier messages of the thread its inputs reply
  # in, and keeps which ones, as it keeps its inputs: they are checked again
  # before its result is applied, may be named as sources, and are recorded as
  # sources of every topic the run writes, so a person forgetting one still
  # reaches what was learned beside it.

  def change do
    alter table(:conversation_learning_runs) do
      add(:context_inputs, :text, null: false, default: "[]")
    end
  end
end
