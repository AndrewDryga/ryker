defmodule Ryker.Operator.Action.Changeset do
  @moduledoc "How an operator action is recorded (`Ryker.Operator.Action`)."
  import Ecto.Changeset
  alias Ryker.Operator.Action

  @fields [
    :action,
    :action_ref,
    :actor_ref,
    :kind,
    :occurred_at,
    :outcome,
    :previous,
    :request_fingerprint,
    :resource_ref
  ]

  @doc "An action a person took, with the state it found and the one it left."
  def insert(attributes) do
    %Action{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_length(:action_ref, min: 1, max: 1_024)
    |> validate_length(:actor_ref, min: 1, max: 1_024)
    |> validate_length(:kind, min: 1, max: 64)
    |> validate_length(:resource_ref, min: 1, max: 1_024)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:action_ref)
    |> check_constraint(:action_ref, name: :ryker_operator_action_valid)
  end
end
