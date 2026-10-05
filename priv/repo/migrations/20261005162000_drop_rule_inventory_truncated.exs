defmodule Ryker.Repo.Migrations.DropRuleInventoryTruncated do
  use Ecto.Migration

  # Every inventory has listed every rule since inventories began; the flag for
  # an inventory that kept fewer was always false (2026-10-04 review: all 185
  # live rows).
  def up do
    alter table(:standing_rule_inventories) do
      remove(:truncated)
    end
  end

  def down do
    alter table(:standing_rule_inventories) do
      add(:truncated, :boolean, null: false, default: false)
    end
  end
end
