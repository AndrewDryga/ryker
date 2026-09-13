defmodule Ryker.Repo.Migrations.RecordStandingRuleInventories do
  use Ecto.Migration

  def change do
    # Every standing rule that existed in the workspace when one input was
    # processed, with the verdict each one actually got.
    #
    # Only matches were ever stored, so a reader could not tell "three rules
    # existed and none matched" from "nobody evaluated any rules", and the two
    # lead to opposite investigations. Today's rules cannot answer it either:
    # a rule edited or deleted since would rewrite the old explanation.
    create table(:standing_rule_inventories, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:source_input_ref, :text, null: false)
      add(:source_event_ref, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:rule_count, :bigint, null: false)
      add(:matched_count, :bigint, null: false)
      add(:truncated, :boolean, null: false, default: false)
      # Canonical JSON text, like every other frozen document here: JSONB would
      # normalize numbers and the entries must reload byte-for-byte.
      add(:entries, :text, null: false)
      add(:recorded_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:standing_rule_inventories, [:source_input_ref]))
    create(index(:standing_rule_inventories, [:recorded_at]))

    create(
      constraint(:standing_rule_inventories, :standing_rule_inventory_valid,
        check: """
        char_length(source_input_ref) BETWEEN 1 AND 1024 AND
        char_length(source_event_ref) BETWEEN 1 AND 1024 AND
        char_length(workspace_ref) BETWEEN 1 AND 1024 AND
        char_length(conversation_ref) BETWEEN 1 AND 1024 AND
        rule_count >= 0 AND matched_count >= 0 AND matched_count <= rule_count AND
        octet_length(entries) BETWEEN 2 AND 262144 AND
        jsonb_typeof(entries::jsonb) = 'array' AND
        jsonb_array_length(entries::jsonb) <= 200
        """
      )
    )
  end
end
