defmodule Ryker.Operator.Action.Query do
  @moduledoc "Audited operator actions, for every read of `ryker_operator_actions`."
  use Ryker, :query
  alias Ryker.Operator.Action

  def all, do: from(actions in Action, as: :ryker_operator_actions)

  def by_action_ref(queryable \\ all(), action_ref),
    do: where(queryable, [ryker_operator_actions: a], a.action_ref == ^action_ref)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
