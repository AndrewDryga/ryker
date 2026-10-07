defmodule Ryker.Ingress.InputCustodyTransitionQuery do
  @moduledoc "Each step a message took through custody, for every read of `input_custody_transitions`."
  import Ecto.Query
  alias Ryker.Ingress.InputCustodyTransition

  def all, do: from(transitions in InputCustodyTransition, as: :input_custody_transitions)

  def by_input_ids(queryable \\ all(), input_ids),
    do: where(queryable, [input_custody_transitions: t], t.input_id in ^input_ids)

  def of_kinds(queryable, kinds),
    do: where(queryable, [input_custody_transitions: t], t.kind in ^kinds)

  def in_order(queryable),
    do: order_by(queryable, [input_custody_transitions: t], asc: t.occurred_at, asc: t.sequence)

  def by_input_id(queryable \\ all(), input_id),
    do: where(queryable, [input_custody_transitions: t], t.input_id == ^input_id)

  def select_last_sequence(queryable),
    do: select(queryable, [input_custody_transitions: t], coalesce(max(t.sequence), 0))
end
