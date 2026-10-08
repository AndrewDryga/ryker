defmodule Ryker.Delivery.RoutingResponse do
  @moduledoc """
  What routing sends by itself, without Work: an emoji reaction on the
  message, or a short message beside it. A decision's messages come first, in
  order, then its reactions, each a response of its own at its `position`,
  all frozen with the routing decision that chose them.
  """
  use Ryker, :schema
  alias Ryker.CanonicalJSON
  alias Ryker.Ingress

  schema "delivery_routing_responses" do
    belongs_to(:input, Ingress.Inbox.Entry)
    field(:position, :integer)
    field(:kind, Ecto.Enum, values: [:reaction, :message])
    field(:decision_ref, :string)
    field(:delivery_ref, :string)
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:source_item_ref, :string)
    field(:document, CanonicalJSON.Type)
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
    field(:external_receipt, CanonicalJSON.Type)
    field(:external_receipt_fingerprint, :string)
    field(:delivered_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{}
end
