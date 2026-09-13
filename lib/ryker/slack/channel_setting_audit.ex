defmodule Ryker.Slack.ChannelSettingAudit do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "slack_channel_setting_audit" do
    field(:event_ref, :string)
    field(:request_fingerprint, :string)
    field(:workspace_ref, :string)
    field(:conversation_ref, :string)
    field(:actor_ref, :string)
    field(:outcome, Ecto.Enum, values: [:updated])
    field(:detail, Ryker.CanonicalJSON.Type)
    field(:occurred_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
