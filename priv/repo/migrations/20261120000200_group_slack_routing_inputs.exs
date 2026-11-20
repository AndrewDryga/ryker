defmodule Ryker.Repo.Migrations.GroupSlackRoutingInputs do
  use Ecto.Migration

  def change do
    alter table(:ingress_inbox_entries) do
      add(:routing_batch_ref, :uuid)
    end

    create(
      index(:ingress_inbox_entries, [:routing_batch_ref], where: "routing_batch_ref IS NOT NULL")
    )
  end
end
