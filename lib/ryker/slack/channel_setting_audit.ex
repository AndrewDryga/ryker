defmodule Ryker.Slack.ChannelSettingAudit do
  @moduledoc false
  use Ryker, :schema

  schema "slack_channel_setting_audit" do
    field(:event_ref, :string)
    field(:request_fingerprint, :string)
    field(:workspace_ref, :string)
    field(:conversation_ref, :string)
    field(:actor_ref, :string)
    field(:outcome, Ecto.Enum, values: [:updated])
    field(:detail, Ryker.CanonicalJSON.Type)
    field(:occurred_at, :utc_datetime_usec)
    timestamps()
  end
end
