defmodule Responder.ControlPlane.CardLabPost do
  @moduledoc "Durable operator-requested Slack specimen and its latest delivery receipt."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "card_lab_posts" do
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:channel_name, :string)
    field(:card_id, :string)
    field(:state_id, :string)
    field(:payload, Responder.CanonicalJSON.Type)
    field(:fingerprint, :string)
    field(:request_fingerprint, :string)
    field(:revision, :integer, default: 1)
    field(:delivered_state_id, :string)
    field(:delivered_fingerprint, :string)
    field(:message_ref, :string)
    field(:status, Ecto.Enum, values: [:pending, :posted, :blocked], default: :pending)
    field(:attempt_count, :integer, default: 0)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_error, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
