defmodule Ryker.Delivery.PlatformAction do
  @moduledoc false

  use Ecto.Schema

  alias Ryker.CanonicalJSON.Type, as: CanonicalJSONType

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "platform_actions" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    belongs_to(:turn, Ryker.Work.Turn)
    field(:action_ref, :string)
    field(:host_slot, :string)

    field(:tool, Ecto.Enum,
      values: [:set_slack_reaction, :post_slack_message, :set_github_reaction]
    )

    field(:kind, Ecto.Enum, values: [:message, :reaction])
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:source_item_ref, :string)
    field(:document, CanonicalJSONType)
    field(:intent_fingerprint, :string)
    field(:status, Ecto.Enum, values: [:pending, :blocked, :delivered], default: :pending)
    field(:attempt_count, :integer, default: 0)
    field(:retry_generation, :integer, default: 0)
    field(:lease_ref, :binary_id)
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
