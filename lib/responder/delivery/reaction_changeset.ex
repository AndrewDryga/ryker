defmodule Responder.Delivery.ReactionChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Delivery.Reaction
  alias Responder.Ingress.Inbox.Entry

  @spec insert(Entry.t(), Ecto.UUID.t(), map(), String.t()) :: Ecto.Changeset.t()
  def insert(%Entry{} = entry, id, document, document_fingerprint) do
    attributes = %{
      attempt_count: 0,
      conversation_ref: entry.destination_conversation_ref,
      decision_ref: entry.decision_ref,
      delivery_ref: "ingress-reaction:#{entry.id}",
      document: document,
      document_fingerprint: document_fingerprint,
      id: id,
      input_id: entry.id,
      source_item_ref: entry.source_item_ref,
      status: :pending,
      thread_ref: entry.destination_thread_ref,
      transport: entry.destination_transport
    }

    %Reaction{}
    |> cast(attributes, Map.keys(attributes))
    |> validate_required(Map.keys(attributes) -- [:thread_ref])
    |> validate_length(:decision_ref, min: 1, max: 1_024)
    |> validate_length(:delivery_ref, min: 1, max: 1_024)
    |> validate_length(:transport, min: 1, max: 1_024)
    |> validate_length(:conversation_ref, min: 1, max: 1_024)
    |> validate_length(:thread_ref, min: 1, max: 1_024)
    |> validate_length(:source_item_ref, min: 1, max: 1_024)
    |> validate_length(:document_fingerprint, is: 64)
    |> unique_constraint(:input_id)
    |> unique_constraint(:delivery_ref)
    |> foreign_key_constraint(:input_id)
    |> reaction_constraints()
  end

  @spec claim(Reaction.t(), map()) :: Ecto.Changeset.t()
  def claim(%Reaction{} = reaction, attributes) do
    reaction
    |> cast(attributes, [
      :attempt_count,
      :last_error_code,
      :last_error_detail,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at
    ])
    |> validate_required([:attempt_count, :lease_expires_at, :lease_owner, :lease_ref])
    |> validate_number(:attempt_count, greater_than: 0)
    |> validate_length(:lease_owner, min: 1, max: 1_024)
    |> validate_length(:lease_ref, min: 1, max: 1_024)
    |> reaction_constraints()
  end

  @spec defer(Reaction.t(), map()) :: Ecto.Changeset.t()
  def defer(%Reaction{} = reaction, attributes) do
    reaction
    |> cast(attributes, [
      :last_error_code,
      :last_error_detail,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at
    ])
    |> validate_required([:last_error_code, :last_error_detail, :next_attempt_at])
    |> validate_length(:last_error_code, min: 1, max: 128)
    |> validate_length(:last_error_detail, min: 1, max: 4_096)
    |> reaction_constraints()
  end

  @spec renew(Reaction.t(), DateTime.t()) :: Ecto.Changeset.t()
  def renew(%Reaction{} = reaction, lease_expires_at) do
    reaction
    |> cast(%{lease_expires_at: lease_expires_at}, [:lease_expires_at])
    |> validate_required([:lease_expires_at, :lease_owner, :lease_ref])
    |> reaction_constraints()
  end

  @spec block(Reaction.t(), map()) :: Ecto.Changeset.t()
  def block(%Reaction{} = reaction, attributes) do
    reaction
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
    |> reaction_constraints()
  end

  @spec retry(Reaction.t()) :: Ecto.Changeset.t()
  def retry(%Reaction{} = reaction) do
    reaction
    |> cast(
      %{
        attempt_count: 0,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        retry_generation: reaction.retry_generation + 1,
        status: :pending
      },
      [
        :attempt_count,
        :last_error_code,
        :last_error_detail,
        :lease_expires_at,
        :lease_owner,
        :lease_ref,
        :next_attempt_at,
        :retry_generation,
        :status
      ]
    )
    |> validate_required([:attempt_count, :retry_generation, :status])
    |> validate_number(:attempt_count, equal_to: 0)
    |> validate_number(:retry_generation, greater_than: 0)
    |> reaction_constraints()
  end

  @spec deliver(Reaction.t(), map(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def deliver(%Reaction{} = reaction, receipt, fingerprint, delivered_at) do
    reaction
    |> cast(
      %{
        delivered_at: delivered_at,
        external_receipt: receipt,
        external_receipt_fingerprint: fingerprint,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :delivered
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
    |> reaction_constraints()
  end

  defp reaction_constraints(changeset) do
    changeset
    |> check_constraint(:document, name: :delivery_reaction_document_valid)
    |> check_constraint(:status, name: :delivery_reaction_custody_valid)
    |> check_constraint(:delivery_ref, name: :delivery_reaction_identity_valid)
  end
end
