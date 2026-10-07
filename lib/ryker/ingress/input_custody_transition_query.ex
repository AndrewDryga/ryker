defmodule Ryker.Ingress.InputCustodyTransitionQuery do
  @moduledoc "Each step a message took through custody, for every read of `input_custody_transitions`."
  import Ecto.Query
  alias Ryker.Ingress.InputCustodyTransition

  def all, do: from(transitions in InputCustodyTransition, as: :input_custody_transitions)

  def by_input_id(queryable \\ all(), input_id),
    do: where(queryable, [input_custody_transitions: t], t.input_id == ^input_id)

  def select_last_sequence(queryable),
    do: select(queryable, [input_custody_transitions: t], coalesce(max(t.sequence), 0))
end
