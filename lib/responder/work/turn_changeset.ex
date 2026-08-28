defmodule Responder.Work.TurnChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Work.Turn

  @maximum_candidate_bytes 256 * 1_024

  @spec insert(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: Ecto.Changeset.t()
  def insert(id, episode_id, session_id, turn_ref) do
    %Turn{}
    |> cast(
      %{
        episode_id: episode_id,
        id: id,
        session_id: session_id,
        status: :pending,
        cancel_generation: 1,
        submit_generation: 1,
        turn_ref: turn_ref,
        validation_generation: 1
      },
      [
        :episode_id,
        :id,
        :session_id,
        :status,
        :cancel_generation,
        :submit_generation,
        :turn_ref,
        :validation_generation
      ]
    )
    |> validate_required([
      :episode_id,
      :id,
      :session_id,
      :status,
      :cancel_generation,
      :submit_generation,
      :turn_ref,
      :validation_generation
    ])
    |> validate_length(:turn_ref, min: 1, max: 1_024)
    |> unique_constraint([:episode_id, :turn_ref])
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:session_id, name: :episode_work_turn_session_episode_fkey)
    |> work_constraints()
  end

  @spec claim(Turn.t(), map()) :: Ecto.Changeset.t()
  def claim(%Turn{} = turn, attributes) do
    turn
    |> cast(attributes, [
      :last_error_code,
      :last_error_detail,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at,
      :cancel_attempt_count,
      :delivery_attempt_count,
      :work_attempt_count
    ])
    |> validate_required([
      :cancel_attempt_count,
      :delivery_attempt_count,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :work_attempt_count
    ])
    |> validate_length(:lease_owner, min: 1, max: 1_024)
    |> validate_length(:lease_ref, min: 1, max: 1_024)
    |> work_constraints()
  end

  @spec freeze(Turn.t(), Responder.Work.Submission.t(), String.t()) :: Ecto.Changeset.t()
  def freeze(%Turn{} = turn, submission, fingerprint) do
    turn
    |> cast(%{submission: submission, submission_fingerprint: fingerprint}, [
      :submission,
      :submission_fingerprint
    ])
    |> validate_required([:submission, :submission_fingerprint])
    |> validate_length(:submission_fingerprint, is: 64)
    |> work_constraints()
  end

  @spec rebind_session(Turn.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def rebind_session(%Turn{} = turn, session_id) do
    turn
    |> cast(%{session_id: session_id}, [:session_id])
    |> validate_required([:session_id])
    |> foreign_key_constraint(:session_id, name: :episode_work_turn_session_episode_fkey)
    |> work_constraints()
  end

  @spec renew(Turn.t(), DateTime.t()) :: Ecto.Changeset.t()
  def renew(%Turn{} = turn, lease_expires_at) do
    turn
    |> cast(%{lease_expires_at: lease_expires_at}, [:lease_expires_at])
    |> validate_required([:lease_expires_at])
    |> work_constraints()
  end

  @spec prepare_remote_operation(Turn.t(), String.t(), String.t(), pos_integer() | nil) ::
          Ecto.Changeset.t()
  def prepare_remote_operation(%Turn{} = turn, kind, key, revision) do
    turn
    |> cast(
      %{
        remote_operation_key: key,
        remote_operation_kind: kind,
        remote_operation_revision: revision
      },
      [
        :remote_operation_key,
        :remote_operation_kind,
        :remote_operation_revision
      ]
    )
    |> validate_required([:remote_operation_key, :remote_operation_kind])
    |> validate_inclusion(:remote_operation_kind, ~w(create_session submit_turn))
    |> validate_length(:remote_operation_key, min: 1, max: 1_024)
    |> work_constraints()
  end

  @spec clear_remote_operation(Turn.t()) :: Ecto.Changeset.t()
  def clear_remote_operation(%Turn{} = turn) do
    turn
    |> cast(
      %{
        remote_operation_key: nil,
        remote_operation_kind: nil,
        remote_operation_revision: nil
      },
      [
        :remote_operation_key,
        :remote_operation_kind,
        :remote_operation_revision
      ]
    )
    |> work_constraints()
  end

  @spec defer(Turn.t(), map()) :: Ecto.Changeset.t()
  def defer(%Turn{} = turn, attributes) do
    turn
    |> cast(attributes, [
      :last_error_code,
      :last_error_detail,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at,
      :status
    ])
    |> validate_required([:last_error_code, :last_error_detail, :next_attempt_at, :status])
    |> validate_length(:last_error_code, min: 1, max: 128)
    |> validate_length(:last_error_detail, min: 1, max: 4_096)
    |> work_constraints()
  end

  @spec yield_progress(Turn.t(), DateTime.t(), atom(), non_neg_integer()) :: Ecto.Changeset.t()
  def yield_progress(%Turn{} = turn, next_attempt_at, attempt_field, attempt_count)
      when attempt_field in [:work_attempt_count, :cancel_attempt_count] do
    attributes =
      %{
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: next_attempt_at
      }
      |> Map.put(attempt_field, attempt_count)

    turn
    |> cast(attributes, [
      :last_error_code,
      :last_error_detail,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at,
      attempt_field
    ])
    |> validate_required([:next_attempt_at, attempt_field])
    |> validate_number(attempt_field, greater_than_or_equal_to: 0)
    |> work_constraints()
  end

  @spec block(Turn.t(), map()) :: Ecto.Changeset.t()
  def block(%Turn{} = turn, attributes) do
    turn
    |> cast(attributes, [
      :last_error_code,
      :last_error_detail,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at,
      :status
    ])
    |> validate_required([:last_error_code, :last_error_detail, :status])
    |> validate_length(:last_error_code, min: 1, max: 128)
    |> validate_length(:last_error_detail, min: 1, max: 4_096)
    |> work_constraints()
  end

  @spec bind_coop_turn(Turn.t(), String.t()) :: Ecto.Changeset.t()
  def bind_coop_turn(%Turn{} = turn, coop_turn_id) do
    turn
    |> cast(%{coop_turn_id: coop_turn_id}, [:coop_turn_id])
    |> validate_required([:coop_turn_id])
    |> validate_length(:coop_turn_id, min: 1, max: 1_024)
    |> unique_constraint(:coop_turn_id)
    |> work_constraints()
  end

  @spec advance_submit(Turn.t(), pos_integer()) :: Ecto.Changeset.t()
  def advance_submit(%Turn{} = turn, submit_generation) do
    turn
    |> cast(%{submit_generation: submit_generation}, [:submit_generation])
    |> validate_required([:submit_generation])
    |> work_constraints()
  end

  @spec stage_candidate(Turn.t(), String.t(), String.t(), pos_integer()) :: Ecto.Changeset.t()
  def stage_candidate(%Turn{} = turn, candidate, candidate_sha256, candidate_attempt) do
    turn
    |> cast(
      %{
        candidate: candidate,
        candidate_attempt: candidate_attempt,
        candidate_sha256: candidate_sha256
      },
      [:candidate, :candidate_attempt, :candidate_sha256]
    )
    |> validate_required([:candidate, :candidate_attempt, :candidate_sha256])
    |> validate_length(:candidate, min: 1, max: @maximum_candidate_bytes, count: :bytes)
    |> validate_length(:candidate_sha256, is: 64)
    |> validate_number(:candidate_attempt, greater_than: 0)
    |> work_constraints()
  end

  @spec replace_candidate(Turn.t(), String.t(), String.t(), pos_integer()) :: Ecto.Changeset.t()
  def replace_candidate(%Turn{} = turn, candidate, candidate_sha256, candidate_attempt) do
    turn
    |> cast(
      %{
        candidate: candidate,
        candidate_attempt: candidate_attempt,
        candidate_sha256: candidate_sha256,
        validation_intent: nil,
        validation_intent_fingerprint: nil,
        validation_generation: 1
      },
      [
        :candidate,
        :candidate_attempt,
        :candidate_sha256,
        :validation_generation,
        :validation_intent,
        :validation_intent_fingerprint
      ]
    )
    |> validate_required([
      :candidate,
      :candidate_attempt,
      :candidate_sha256,
      :validation_generation
    ])
    |> validate_length(:candidate, min: 1, max: @maximum_candidate_bytes, count: :bytes)
    |> validate_length(:candidate_sha256, is: 64)
    |> validate_number(:candidate_attempt, greater_than: 0)
    |> work_constraints()
  end

  @spec prepare_validation(Turn.t(), map(), String.t()) :: Ecto.Changeset.t()
  def prepare_validation(%Turn{} = turn, intent, fingerprint) do
    turn
    |> cast(
      %{validation_intent: intent, validation_intent_fingerprint: fingerprint},
      [:validation_intent, :validation_intent_fingerprint]
    )
    |> validate_required([:validation_intent, :validation_intent_fingerprint])
    |> validate_length(:validation_intent_fingerprint, is: 64)
    |> work_constraints()
  end

  @spec advance_validation(Turn.t(), pos_integer()) :: Ecto.Changeset.t()
  def advance_validation(%Turn{} = turn, validation_generation) do
    turn
    |> cast(%{validation_generation: validation_generation}, [:validation_generation])
    |> validate_required([:validation_generation])
    |> work_constraints()
  end

  @spec prepare_cancellation(Turn.t(), map(), String.t(), DateTime.t() | nil) ::
          Ecto.Changeset.t()
  def prepare_cancellation(%Turn{} = turn, intent, fingerprint, not_before) do
    turn
    |> cast(
      %{
        cancellation_intent: intent,
        cancellation_intent_fingerprint: fingerprint,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: not_before,
        status: :cancel_pending
      },
      [
        :cancellation_intent,
        :cancellation_intent_fingerprint,
        :last_error_code,
        :last_error_detail,
        :lease_expires_at,
        :lease_owner,
        :lease_ref,
        :next_attempt_at,
        :status
      ]
    )
    |> validate_required([:cancellation_intent, :cancellation_intent_fingerprint, :status])
    |> validate_length(:cancellation_intent_fingerprint, is: 64)
    |> work_constraints()
  end

  @spec advance_cancel(Turn.t(), pos_integer()) :: Ecto.Changeset.t()
  def advance_cancel(%Turn{} = turn, cancel_generation) do
    turn
    |> cast(
      %{
        cancel_expected_revision: nil,
        cancel_generation: cancel_generation,
        close_expected_revision: nil
      },
      [:cancel_expected_revision, :cancel_generation, :close_expected_revision]
    )
    |> validate_required([:cancel_generation])
    |> work_constraints()
  end

  @spec freeze_cancellation_revision(Turn.t(), atom(), pos_integer()) :: Ecto.Changeset.t()
  def freeze_cancellation_revision(%Turn{} = turn, phase, revision)
      when phase in [:cancel_turn, :close_session] do
    field =
      case phase do
        :cancel_turn -> :cancel_expected_revision
        :close_session -> :close_expected_revision
      end

    turn
    |> cast(%{field => revision}, [field])
    |> validate_required([field])
    |> validate_number(field, greater_than: 0)
    |> work_constraints()
  end

  @spec settle_cancellation(
          Turn.t(),
          map(),
          String.t(),
          DateTime.t(),
          String.t(),
          String.t(),
          atom()
        ) ::
          Ecto.Changeset.t()
  def settle_cancellation(
        %Turn{} = turn,
        receipt,
        fingerprint,
        cancelled_at,
        error_code,
        error_detail,
        status
      ) do
    turn
    |> cast(
      %{
        cancellation_receipt: receipt,
        cancellation_receipt_fingerprint: fingerprint,
        cancel_expected_revision: nil,
        cancelled_at: cancelled_at,
        close_expected_revision: nil,
        last_error_code: error_code,
        last_error_detail: error_detail,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        remote_operation_key: nil,
        remote_operation_kind: nil,
        remote_operation_revision: nil,
        status: status
      },
      [
        :cancellation_receipt,
        :cancellation_receipt_fingerprint,
        :cancel_expected_revision,
        :cancelled_at,
        :close_expected_revision,
        :last_error_code,
        :last_error_detail,
        :lease_expires_at,
        :lease_owner,
        :lease_ref,
        :next_attempt_at,
        :remote_operation_key,
        :remote_operation_kind,
        :remote_operation_revision,
        :status
      ]
    )
    |> validate_required([
      :cancellation_receipt,
      :cancellation_receipt_fingerprint,
      :cancelled_at,
      :last_error_code,
      :last_error_detail,
      :status
    ])
    |> validate_length(:cancellation_receipt_fingerprint, is: 64)
    |> validate_length(:last_error_code, min: 1, max: 128)
    |> validate_length(:last_error_detail, min: 1, max: 4_096)
    |> work_constraints()
  end

  @spec replace_cancellation_disposition(
          Turn.t(),
          map(),
          String.t(),
          String.t(),
          String.t(),
          atom()
        ) :: Ecto.Changeset.t()
  def replace_cancellation_disposition(
        %Turn{} = turn,
        intent,
        fingerprint,
        error_code,
        error_detail,
        status
      ) do
    turn
    |> cast(
      %{
        cancellation_intent: intent,
        cancellation_intent_fingerprint: fingerprint,
        last_error_code: error_code,
        last_error_detail: error_detail,
        status: status
      },
      [
        :cancellation_intent,
        :cancellation_intent_fingerprint,
        :last_error_code,
        :last_error_detail,
        :status
      ]
    )
    |> validate_required([
      :cancellation_intent,
      :cancellation_intent_fingerprint,
      :last_error_code,
      :last_error_detail,
      :status
    ])
    |> validate_length(:cancellation_intent_fingerprint, is: 64)
    |> validate_length(:last_error_code, min: 1, max: 128)
    |> validate_length(:last_error_detail, min: 1, max: 4_096)
    |> work_constraints()
  end

  @spec accept_result(Turn.t(), map()) :: Ecto.Changeset.t()
  def accept_result(%Turn{} = turn, attributes) do
    turn
    |> cast(attributes, [
      :accepted_at,
      :continuation,
      :delivery_document,
      :delivery_fingerprint,
      :delivery_ref,
      :last_error_code,
      :last_error_detail,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at,
      :result_ref,
      :status,
      :validation_receipt
    ])
    |> validate_required([
      :accepted_at,
      :continuation,
      :result_ref,
      :status,
      :validation_receipt
    ])
    |> validate_length(:result_ref, min: 1, max: 1_024)
    |> validate_length(:validation_receipt, min: 1, max: 4_096)
    |> validate_length(:delivery_ref, min: 1, max: 1_024)
    |> validate_length(:delivery_fingerprint, is: 64)
    |> unique_constraint(:result_ref)
    |> unique_constraint(:delivery_ref)
    |> work_constraints()
  end

  @spec confirm_delivery(Turn.t(), map(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def confirm_delivery(%Turn{} = turn, external_receipt, receipt_fingerprint, delivered_at) do
    turn
    |> cast(
      %{
        delivered_at: delivered_at,
        external_receipt: external_receipt,
        external_receipt_fingerprint: receipt_fingerprint,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :settled
      },
      [
        :delivered_at,
        :external_receipt,
        :external_receipt_fingerprint,
        :last_error_code,
        :last_error_detail,
        :lease_expires_at,
        :lease_owner,
        :lease_ref,
        :next_attempt_at,
        :status
      ]
    )
    |> validate_required([
      :delivered_at,
      :external_receipt,
      :external_receipt_fingerprint,
      :status
    ])
    |> validate_length(:external_receipt_fingerprint, is: 64)
    |> work_constraints()
  end

  defp work_constraints(changeset) do
    changeset
    |> check_constraint(:turn_ref, name: :episode_work_turn_identity_valid)
    |> check_constraint(:submit_generation, name: :episode_work_turn_generations_valid)
    |> check_constraint(:submission, name: :episode_work_turn_submission_valid)
    |> check_constraint(:remote_operation_kind,
      name: :episode_work_turn_remote_operation_valid
    )
    |> check_constraint(:candidate, name: :episode_work_turn_candidate_valid)
    |> check_constraint(:validation_intent, name: :episode_work_turn_validation_intent_valid)
    |> check_constraint(:cancellation_intent, name: :episode_work_turn_cancellation_valid)
    |> check_constraint(:delivery_ref, name: :episode_work_turn_delivery_valid)
    |> check_constraint(:status, name: :episode_work_turn_custody_valid)
  end
end
