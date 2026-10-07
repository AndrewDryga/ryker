defmodule Ryker.Delivery.RoutingResponse.Changeset do
  @moduledoc false

  import Ecto.Changeset
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Ingress.Inbox.Entry

  @spec insert(Entry.t(), Ecto.UUID.t(), pos_integer(), :reaction | :message, map(), String.t()) ::
          Ecto.Changeset.t()
  def insert(%Entry{} = entry, id, position, kind, document, document_fingerprint) do
    attributes = %{
      attempt_count: 0,
      conversation_ref: entry.destination_conversation_ref,
      decision_ref: entry.decision_ref,
      delivery_ref: "ingress-#{kind}:#{entry.id}:#{position}",
      document: document,
      document_fingerprint: document_fingerprint,
      id: id,
      input_id: entry.id,
      kind: kind,
      position: position,
      source_item_ref: entry.source_item_ref,
      status: :pending,
      thread_ref: entry.destination_thread_ref,
      transport: entry.destination_transport
    }

    %RoutingResponse{}
    |> cast(attributes, Map.keys(attributes))
    |> validate_required(Map.keys(attributes) -- [:thread_ref])
    |> validate_length(:decision_ref, min: 1, max: 1_024)
    |> validate_length(:delivery_ref, min: 1, max: 1_024)
    |> validate_length(:transport, min: 1, max: 1_024)
    |> validate_length(:conversation_ref, min: 1, max: 1_024)
    |> validate_length(:thread_ref, min: 1, max: 1_024)
    |> validate_length(:source_item_ref, min: 1, max: 1_024)
    |> validate_length(:document_fingerprint, is: 64)
    |> validate_number(:position, greater_than_or_equal_to: 1, less_than_or_equal_to: 6)
    |> unique_constraint([:input_id, :position],
      name: :delivery_routing_responses_input_position_index
    )
    |> unique_constraint(:delivery_ref)
    |> foreign_key_constraint(:input_id)
    |> response_constraints()
  end

  @spec claim(RoutingResponse.t(), map()) :: Ecto.Changeset.t()
  def claim(%RoutingResponse{} = response, attributes) do
    response
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
    |> response_constraints()
  end

  @spec defer(RoutingResponse.t(), map()) :: Ecto.Changeset.t()
  def defer(%RoutingResponse{} = response, attributes) do
    response
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
    |> response_constraints()
  end

  @spec renew(RoutingResponse.t(), DateTime.t()) :: Ecto.Changeset.t()
  def renew(%RoutingResponse{} = response, lease_expires_at) do
    response
    |> cast(%{lease_expires_at: lease_expires_at}, [:lease_expires_at])
    |> validate_required([:lease_expires_at, :lease_owner, :lease_ref])
    |> response_constraints()
  end

  @spec block(RoutingResponse.t(), map()) :: Ecto.Changeset.t()
  def block(%RoutingResponse{} = response, attributes) do
    response
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
    |> response_constraints()
  end

  @spec retry(RoutingResponse.t()) :: Ecto.Changeset.t()
  def retry(%RoutingResponse{} = response) do
    response
    |> cast(
      %{
        attempt_count: 0,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        retry_generation: response.retry_generation + 1,
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
    |> response_constraints()
  end

  @spec deliver(RoutingResponse.t(), map(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def deliver(%RoutingResponse{} = response, receipt, fingerprint, delivered_at) do
    response
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
    |> response_constraints()
  end

  defp response_constraints(changeset) do
    changeset
    |> check_constraint(:document, name: :delivery_routing_response_document_valid)
    |> check_constraint(:status, name: :delivery_routing_response_custody_valid)
    |> check_constraint(:delivery_ref, name: :delivery_routing_response_identity_valid)
    |> check_constraint(:position, name: :delivery_routing_response_position_valid)
  end
end
