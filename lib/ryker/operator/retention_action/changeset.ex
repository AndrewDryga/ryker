defmodule Ryker.Operator.RetentionAction.Changeset do
  @moduledoc "How a person's retention action is recorded (`Ryker.Operator.RetentionAction`)."
  use Ryker, :changeset
  alias Ryker.Operator.RetentionAction

  @fields [
    :id,
    :session_id,
    :action_ref,
    :request_fingerprint,
    :actor_ref,
    :action,
    :previous_status,
    :result_status,
    :previous_plan_fingerprint,
    :occurred_at
  ]
  # Rearming a session that had no discard plan records no plan fingerprint.
  @required @fields -- [:previous_plan_fingerprint]

  @doc "An action a person took on a session's cleanup, and the status it left."
  def insert(attributes) do
    %RetentionAction{}
    |> cast(attributes, @fields)
    |> validate_required(@required)
    |> validate_length(:action_ref, min: 1, max: 1_024)
    |> validate_length(:actor_ref, min: 1, max: 1_024)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:action_ref)
    |> foreign_key_constraint(:session_id)
    |> check_constraint(:action_ref, name: :retention_operator_action_valid)
  end
end
