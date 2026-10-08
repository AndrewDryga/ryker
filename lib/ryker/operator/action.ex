defmodule Ryker.Operator.Action do
  @moduledoc false
  use Ryker, :schema
  alias Ryker.CanonicalJSON

  schema "ryker_operator_actions" do
    field(:action_ref, :string)
    field(:request_fingerprint, :string)
    field(:actor_ref, :string)
    field(:action, Ecto.Enum, values: [:retry, :replay, :update, :discard])
    field(:kind, :string)
    field(:resource_ref, :string)
    field(:previous, CanonicalJSON.Type)
    field(:outcome, CanonicalJSON.Type)
    field(:occurred_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{}
end
