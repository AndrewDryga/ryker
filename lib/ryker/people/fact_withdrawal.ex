defmodule Ryker.People.FactWithdrawal do
  @moduledoc """
  Content-free protection against relearning withdrawn personal facts.

  A nil `source_message_ref` rejects statements made at or before `withdrawn_at`.
  A named source is blocked across revisions, regardless of the model's fact key.
  These records survive replacement of a person's current fact rows.
  """
  use Ryker, :schema

  schema "person_fact_withdrawals" do
    field(:person_ref, :string)
    field(:source_message_ref, :string)
    field(:withdrawn_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
