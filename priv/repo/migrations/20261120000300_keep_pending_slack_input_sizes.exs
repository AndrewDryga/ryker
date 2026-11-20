defmodule Ryker.Repo.Migrations.KeepPendingSlackInputSizes do
  use Ecto.Migration

  def change do
    alter table(:episode_kernel_episodes) do
      add(:slack_input_costs, :map, null: false, default: %{})
    end
  end
end
