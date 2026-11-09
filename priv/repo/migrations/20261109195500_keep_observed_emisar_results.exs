defmodule Ryker.Repo.Migrations.KeepObservedEmisarResults do
  use Ecto.Migration

  def change do
    alter table(:episode_work_state_tool_calls) do
      add(:emisar_run, :map)
      add(:answered_at, :utc_datetime_usec)
    end
  end
end
