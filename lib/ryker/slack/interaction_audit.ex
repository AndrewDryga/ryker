defmodule Ryker.Slack.InteractionAudit do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "slack_interaction_audit" do
    field(:event_ref, :string)
    field(:request_fingerprint, :string)
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:thread_ref, :string)
    field(:message_ref, :string)
    field(:actor_ref, :string)
    field(:action_id, :string)
    field(:action_value_digest, :string)
    field(:outcome, Ecto.Enum, values: [:denied, :invalid, :confirmed])
    field(:repaint_status, Ecto.Enum, values: [:none, :pending, :settled, :blocked])
    field(:attempt_count, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_owner, :string)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:repainted_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
