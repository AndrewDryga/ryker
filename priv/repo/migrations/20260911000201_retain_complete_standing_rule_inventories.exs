defmodule Ryker.Repo.Migrations.RetainCompleteStandingRuleInventories do
  use Ecto.Migration

  def up do
    drop(constraint(:standing_rule_inventories, :standing_rule_inventory_valid))

    create(
      constraint(:standing_rule_inventories, :standing_rule_inventory_valid,
        check: complete_inventory_check()
      )
    )
  end

  def down do
    drop(constraint(:standing_rule_inventories, :standing_rule_inventory_valid))

    create(
      constraint(:standing_rule_inventories, :standing_rule_inventory_valid,
        check: bounded_inventory_check()
      )
    )
  end

  # Workspace rules are already bounded by the behavior store. This evidence
  # constraint validates the retained document without independently cutting
  # the inventory off at 200 entries or rejecting the complete JSON by size.
  defp complete_inventory_check do
    """
    char_length(source_input_ref) BETWEEN 1 AND 1024 AND
    char_length(source_event_ref) BETWEEN 1 AND 1024 AND
    char_length(workspace_ref) BETWEEN 1 AND 1024 AND
    char_length(conversation_ref) BETWEEN 1 AND 1024 AND
    rule_count >= 0 AND matched_count >= 0 AND matched_count <= rule_count AND
    octet_length(entries) >= 2 AND
    jsonb_typeof(entries::jsonb) = 'array'
    """
  end

  defp bounded_inventory_check do
    """
    char_length(source_input_ref) BETWEEN 1 AND 1024 AND
    char_length(source_event_ref) BETWEEN 1 AND 1024 AND
    char_length(workspace_ref) BETWEEN 1 AND 1024 AND
    char_length(conversation_ref) BETWEEN 1 AND 1024 AND
    rule_count >= 0 AND matched_count >= 0 AND matched_count <= rule_count AND
    octet_length(entries) BETWEEN 2 AND 262144 AND
    jsonb_typeof(entries::jsonb) = 'array' AND
    jsonb_array_length(entries::jsonb) <= 200
    """
  end
end
