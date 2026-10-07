defmodule Ryker.Learning.InputMembership.Query do
  @moduledoc "Which batch holds each message learning takes, for every read of `conversation_learning_inputs`."
  use Ryker, :query
  alias Ryker.Learning.InputMembership

  def all, do: from(memberships in InputMembership, as: :conversation_learning_inputs)

  def by_batch_id(queryable \\ all(), batch_id),
    do: where(queryable, [conversation_learning_inputs: m], m.batch_id == ^batch_id)

  def by_input_id(queryable, input_id),
    do: where(queryable, [conversation_learning_inputs: m], m.input_id == ^input_id)

  def by_input_ids(queryable, input_ids),
    do: where(queryable, [conversation_learning_inputs: m], m.input_id in ^input_ids)

  def excluding_input_ids(queryable, input_ids),
    do: where(queryable, [conversation_learning_inputs: m], m.input_id not in ^input_ids)

  @doc "Memberships the batch still learns from: none has a terminal reason."
  def unfinished(queryable),
    do: where(queryable, [conversation_learning_inputs: m], is_nil(m.terminal_reason))

  @doc "Memberships retired for any reason but `reason`."
  def retired_except(queryable, reason),
    do: where(queryable, [conversation_learning_inputs: m], m.terminal_reason != ^reason)

  @doc "Memberships not retired for `reason`: unfinished, or retired for another."
  def not_retired_for(queryable, reason) do
    where(
      queryable,
      [conversation_learning_inputs: m],
      is_nil(m.terminal_reason) or m.terminal_reason != ^reason
    )
  end

  def select_input_ids(queryable),
    do: select(queryable, [conversation_learning_inputs: m], m.input_id)
end
