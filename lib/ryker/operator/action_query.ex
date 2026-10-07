defmodule Ryker.Operator.ActionQuery do
  @moduledoc "Audited operator actions, for every read of `ryker_operator_actions`."
  import Ecto.Query
  alias Ryker.Operator.Action

  def all, do: from(actions in Action, as: :ryker_operator_actions)

  def by_action_ref(queryable \\ all(), action_ref),
    do: where(queryable, [ryker_operator_actions: a], a.action_ref == ^action_ref)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
