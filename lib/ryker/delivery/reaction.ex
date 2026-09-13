defmodule Ryker.Delivery.Reaction do
  @moduledoc false

  use Ecto.Schema

  alias Ryker.CanonicalJSON.Type, as: CanonicalJSONType
  alias Ryker.Ingress.Inbox.Entry

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "delivery_reactions" do
    belongs_to(:input, Entry)
    field(:decision_ref, :string)
    field(:delivery_ref, :string)
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:source_item_ref, :string)
    field(:document, CanonicalJSONType)
    field(:document_fingerprint, :string)
    field(:status, Ecto.Enum, values: [:pending, :blocked, :delivered], default: :pending)
    field(:attempt_count, :integer, default: 0)
    field(:retry_generation, :integer, default: 0)
    field(:lease_ref, :string)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    field(:external_receipt, CanonicalJSONType)
    field(:external_receipt_fingerprint, :string)
    field(:delivered_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
