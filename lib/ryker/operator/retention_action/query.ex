defmodule Ryker.Operator.RetentionAction.Query do
  @moduledoc "Audited cleanup actions on working copies, for every read of `retention_operator_actions`."
  use Ryker, :query
  alias Ryker.Operator.RetentionAction

  def all, do: from(actions in RetentionAction, as: :retention_operator_actions)

  def by_action_ref(queryable \\ all(), action_ref),
    do: where(queryable, [retention_operator_actions: a], a.action_ref == ^action_ref)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
