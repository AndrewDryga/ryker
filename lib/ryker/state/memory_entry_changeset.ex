defmodule Ryker.State.MemoryEntryChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.State.MemoryEntry

  @insert_fields [
    :answer_provenance,
    :confirmation_ref,
    :confirmed_at,
    :confirmed_by_actor_ref,
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

  @normal_required @insert_fields -- [:answer_provenance, :source_thread_ref]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %MemoryEntry{}
    |> cast(attributes, @insert_fields)
    |> required_fields()
    |> validate()
  end

  defp required_fields(changeset) do
    if get_field(changeset, :scope_kind) == :global do
      validate_required(changeset, [
        :answer_provenance | @normal_required -- [:offer_record_id, :expires_at]
      ])
    else
      validate_required(changeset, @normal_required)
    end
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
    |> unique_constraint(:confirmation_ref, name: :operational_memory_answer_confirmation)
    |> unique_constraint(:subject, name: :operational_memory_active_identity)
    |> foreign_key_constraint(:offer_record_id)
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

  @spec review(MemoryEntry.t(), DateTime.t()) :: Ecto.Changeset.t()
  def review(%MemoryEntry{} = entry, %DateTime{} = reviewed_at) do
    change(entry, last_reviewed_at: reviewed_at)
  end

  @spec edit(MemoryEntry.t(), String.t(), map(), String.t(), DateTime.t(), String.t(), String.t()) ::
          Ecto.Changeset.t()
  def edit(
        %MemoryEntry{} = entry,
        subject,
        payload,
        fingerprint,
        %DateTime{} = reviewed_at,
        actor_ref,
        review_ref
      ) do
    entry
    |> cast(
      %{
        last_reviewed_at: reviewed_at,
        edited_at: reviewed_at,
        edited_by_actor_ref: actor_ref,
        edit_review_ref: review_ref,
        payload: payload,
        payload_fingerprint: fingerprint,
        subject: subject
      },
      [
        :edited_at,
        :edited_by_actor_ref,
        :edit_review_ref,
        :last_reviewed_at,
        :payload,
        :payload_fingerprint,
        :subject
      ]
    )
    |> validate_required([
      :edited_at,
      :edited_by_actor_ref,
      :edit_review_ref,
      :last_reviewed_at,
      :payload,
      :payload_fingerprint,
      :subject
    ])
    |> validate_length(:subject, min: 1, max: 120)
    |> validate_length(:edited_by_actor_ref, min: 1, max: 1_024)
    |> validate_length(:edit_review_ref, min: 1, max: 256)
    |> validate_format(:payload_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:subject, name: :operational_memory_active_identity)
    |> check_constraint(:edited_at, name: :operational_memory_edit_provenance_valid)
    |> check_constraint(:status, name: :operational_memory_entry_valid)
  end
end
