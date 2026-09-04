defmodule Responder.Operator.Action do
  @moduledoc false

  use Ecto.Schema

  alias Responder.CanonicalJSON.Type, as: CanonicalJSONType

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "responder_operator_actions" do
    field(:action_ref, :string)
    field(:request_fingerprint, :string)
    field(:actor_ref, :string)
    field(:action, Ecto.Enum, values: [:retry, :replay, :update, :discard])
    field(:kind, :string)
    field(:resource_ref, :string)
    field(:previous, CanonicalJSONType)
    field(:outcome, CanonicalJSONType)
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
