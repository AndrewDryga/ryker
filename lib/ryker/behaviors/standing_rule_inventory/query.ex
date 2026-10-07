defmodule Ryker.Behaviors.StandingRuleInventory.Query do
  @moduledoc "The standing rules recorded for each input, for every read of `standing_rule_inventories`."
  import Ecto.Query
  alias Ryker.Behaviors.StandingRuleInventory

  def all, do: from(inventories in StandingRuleInventory, as: :standing_rule_inventories)

  def by_source_input_ref(queryable \\ all(), input_ref),
    do: where(queryable, [standing_rule_inventories: i], i.source_input_ref == ^input_ref)

  def by_source_input_refs(queryable \\ all(), input_refs),
    do: where(queryable, [standing_rule_inventories: i], i.source_input_ref in ^input_refs)
end
