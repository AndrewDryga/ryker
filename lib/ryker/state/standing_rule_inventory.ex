defmodule Ryker.State.StandingRuleInventory do
  @moduledoc """
  Every standing rule that existed in one workspace when one input processed.

  Only matches were ever recorded, which left the two most common questions
  unanswerable: did three rules exist and none match, or did nobody evaluate
  any rules? Those lead to opposite investigations. Reading today's rules
  cannot answer it either -- a rule edited or deleted since would quietly
  rewrite the old explanation.

  The row is written once per input and never updated, so a later rule change
  cannot reach back into it.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "standing_rule_inventories" do
    field(:source_input_ref, :string)
    field(:source_event_ref, :string)
    field(:workspace_ref, :string)
    field(:conversation_ref, :string)
    field(:rule_count, :integer)
    field(:matched_count, :integer)
    field(:truncated, :boolean, default: false)
    field(:entries, Ryker.CanonicalJSON.Type)
    field(:recorded_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
