defmodule Ryker.State.RecordChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.State.{Record, RecordPayload}

  @fields [
    :continuation,
    :cutover_item_id,
    :confirmed_at,
    :confirmed_by_actor_ref,
    :confirmed_episode_id,
    :confirmation_ref,
    :episode_id,
    :id,
    :kind,
    :operation_id,
    :payload,
    :payload_fingerprint,
    :ref,
    :status,
    :subject_ref,
    :turn_id
  ]

  @insert_required [
    :episode_id,
    :id,
    :kind,
    :operation_id,
    :payload,
    :payload_fingerprint,
    :ref,
    :status,
    :turn_id
  ]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %Record{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> validate_length(:ref, min: 1, max: 256)
    |> validate_length(:operation_id, min: 1, max: 80)
    |> validate_inclusion(:kind, RecordPayload.kinds())
    |> validate_length(:subject_ref, min: 1, max: 120)
    |> validate_format(:payload_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:ref)
    |> unique_constraint(:operation_id,
      name: :episode_state_records_turn_id_operation_id_index
    )
    |> unique_constraint(:subject_ref, name: :episode_state_record_goal_subject_index)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:turn_id, name: :episode_state_record_turn_episode_fkey)
    |> unique_constraint(:cutover_item_id)
    |> foreign_key_constraint(:cutover_item_id)
    |> check_constraint(:turn_id, name: :episode_state_record_provenance_valid)
    |> check_constraint(:kind, name: :episode_state_record_identity_valid)
  end

  @spec confirm(Record.t(), map()) :: Ecto.Changeset.t()
  def confirm(%Record{} = record, attributes) do
    record
    |> cast(attributes, [
      :confirmed_at,
      :confirmed_by_actor_ref,
      :confirmed_episode_id,
      :confirmation_ref,
      :status
    ])
    |> validate_required([
      :confirmed_at,
      :confirmed_by_actor_ref,
      :confirmed_episode_id,
      :confirmation_ref,
      :status
    ])
    |> validate_inclusion(:status, [:confirmed])
    |> validate_length(:confirmation_ref, min: 1, max: 1_024)
    |> validate_length(:confirmed_by_actor_ref, min: 1, max: 1_024)
    |> foreign_key_constraint(:confirmed_episode_id)
    |> unique_constraint(:confirmed_episode_id)
    |> check_constraint(:status, name: :episode_state_record_confirmation_valid)
  end

  @spec confirm_resource(Record.t(), map()) :: Ecto.Changeset.t()
  def confirm_resource(%Record{} = record, attributes) do
    record
    |> cast(attributes, [:confirmed_at, :confirmed_by_actor_ref, :confirmation_ref, :status])
    |> validate_required([:confirmed_at, :confirmed_by_actor_ref, :confirmation_ref, :status])
    |> validate_inclusion(:status, [:confirmed])
    |> validate_length(:confirmation_ref, min: 1, max: 1_024)
    |> validate_length(:confirmed_by_actor_ref, min: 1, max: 1_024)
    |> check_constraint(:status, name: :episode_state_record_confirmation_valid)
  end

  @spec answer(Record.t()) :: Ecto.Changeset.t()
  def answer(%Record{} = record) do
    record
    |> change(status: :answered)
    |> check_constraint(:status, name: :episode_state_record_identity_valid)
    |> check_constraint(:status, name: :episode_state_record_confirmation_valid)
  end
end
