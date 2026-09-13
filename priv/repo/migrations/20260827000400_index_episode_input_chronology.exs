defmodule Ryker.Repo.Migrations.IndexEpisodeInputChronology do
  use Ecto.Migration

  def change do
    create(
      index(:episode_kernel_events, [:episode_id, :kind, :occurred_at, :sequence],
        name: :episode_kernel_input_chronology
      )
    )
  end
end
