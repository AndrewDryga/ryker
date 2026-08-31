defmodule Responder.State.MemoryEntryChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.State.MemoryEntry

  @insert_fields [
    :confirmation_ref,
    :confirmed_at,
    :confirmed_by_actor_ref,
    :cutover_item_id,
    :expires_at,
    :id,
    :kind,
    :offer_record_id,
    :payload,
    :payload_fingerprint,
    :ref,
    :scope_kind,
    :scope_ref,
    :source_conversation_ref,
    :source_message_ref,
    :source_thread_ref,
    :source_transport,
    :status,
    :subject,
    :visibility,
    :workspace_ref
  ]

  @normal_required @insert_fields -- [:cutover_item_id, :source_thread_ref]
  @cutover_required @insert_fields -- [:offer_record_id, :source_thread_ref]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %MemoryEntry{}
    |> cast(attributes, @insert_fields)
    |> validate_required(@normal_required)
    |> validate()
  end

  @doc false
  @spec cutover(map()) :: Ecto.Changeset.t()
  def cutover(attributes) do
    %MemoryEntry{}
    |> cast(attributes, @insert_fields)
    |> validate_required(@cutover_required)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> validate_length(:ref, min: 1, max: 256)
    |> validate_length(:workspace_ref, min: 1, max: 1_024)
    |> validate_length(:scope_ref, min: 1, max: 1_024)
    |> validate_length(:subject, min: 1, max: 120)
    |> validate_length(:confirmed_by_actor_ref, min: 1, max: 1_024)
    |> validate_length(:confirmation_ref, min: 1, max: 1_024)
    |> validate_length(:source_transport, min: 1, max: 1_024)
    |> validate_length(:source_conversation_ref, min: 1, max: 1_024)
    |> validate_length(:source_thread_ref, min: 1, max: 1_024)
    |> validate_length(:source_message_ref, min: 1, max: 1_024)
    |> validate_format(:payload_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:ref)
    |> unique_constraint(:offer_record_id)
    |> unique_constraint(:cutover_item_id)
    |> unique_constraint(:subject, name: :operational_memory_active_identity)
    |> foreign_key_constraint(:offer_record_id)
    |> foreign_key_constraint(:cutover_item_id)
    |> check_constraint(:offer_record_id, name: :operational_memory_provenance_valid)
    |> check_constraint(:kind, name: :operational_memory_entry_valid)
  end

  @spec redact(MemoryEntry.t(), :deleted | :superseded | :expired, map(), String.t()) ::
          Ecto.Changeset.t()
  def redact(%MemoryEntry{} = entry, status, payload, fingerprint)
      when status in [:deleted, :superseded, :expired] do
    entry
    |> cast(%{payload: payload, payload_fingerprint: fingerprint, status: status}, [
      :payload,
      :payload_fingerprint,
      :status
    ])
    |> validate_required([:payload, :payload_fingerprint, :status])
    |> validate_format(:payload_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> check_constraint(:status, name: :operational_memory_entry_valid)
  end
end
