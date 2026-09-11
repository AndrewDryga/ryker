defmodule Responder.Emisar.ApprovalChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Emisar.{Approval, RunState}

  @fields [
    :action_id,
    :approval_url,
    :episode_id,
    :expires_at,
    :failure_count,
    :id,
    :last_error,
    :last_observed_at,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :next_attempt_at,
    :operation_id,
    :pack_ref,
    :record_id,
    :remote_error,
    :remote_status,
    :request_id,
    :resumed_at,
    :review_digest,
    :run_id,
    :run_url,
    :runner_ref,
    :status,
    :terminal_at
  ]

  @insert_required [
    :action_id,
    :approval_url,
    :episode_id,
    :expires_at,
    :id,
    :operation_id,
    :pack_ref,
    :record_id,
    :remote_status,
    :request_id,
    :run_id,
    :runner_ref,
    :status
  ]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %Approval{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> validate_common()
    |> unique_constraint(:record_id)
    |> unique_constraint(:request_id)
    |> foreign_key_constraint(:record_id)
    |> foreign_key_constraint(:episode_id)
  end

  @spec update(Approval.t(), map()) :: Ecto.Changeset.t()
  def update(%Approval{} = approval, attributes) do
    approval
    |> cast(attributes, @fields)
    |> validate_common()
  end

  defp validate_common(changeset) do
    changeset
    |> validate_length(:request_id, min: 1, max: 80)
    |> validate_length(:run_id, min: 1, max: 200)
    |> validate_length(:operation_id, min: 1, max: 200)
    |> validate_length(:action_id, min: 1, max: 200)
    |> validate_length(:pack_ref, min: 1, max: 300)
    |> validate_length(:runner_ref, min: 1, max: 300)
    |> validate_length(:approval_url, min: 1, max: 2_048)
    |> validate_length(:run_url, min: 1, max: 2_048)
    |> validate_length(:remote_error, min: 1, max: 1_000)
    |> validate_length(:review_digest, is: 64)
    |> validate_length(:last_error, min: 1, max: 4_096)
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, [:monitoring, :resumed, :blocked])
    |> validate_inclusion(:remote_status, RunState.statuses())
    |> check_constraint(:status, name: :episode_emisar_approval_identity_valid)
    |> check_constraint(:lease_ref, name: :episode_emisar_approval_lease_valid)
    |> check_constraint(:review_digest, name: :episode_emisar_approval_review_valid)
  end
end
