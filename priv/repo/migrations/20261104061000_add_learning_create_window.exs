defmodule Ryker.Repo.Migrations.AddLearningCreateWindow do
  use Ecto.Migration

  def change do
    alter table(:conversation_learning_runs) do
      add(:create_window_started_at, :utc_datetime_usec)
    end
  end
end
