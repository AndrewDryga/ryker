defmodule Ryker.Repo.Migrations.AddLearningSubmitClock do
  use Ecto.Migration

  def change do
    alter table(:conversation_learning_runs) do
      add(:submit_started_at, :utc_datetime_usec)
    end
  end
end
