defmodule Responder.Slack.ChannelSettingOverride do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "slack_channel_setting_overrides" do
    field(:workspace_ref, :string)
    field(:scope_kind, Ecto.Enum, values: [:channel, :workspace])
    field(:scope_ref, :string)
    field(:setting, Ecto.Enum, values: [:proactive, :shadow])
    field(:value, :boolean)
    field(:actor_ref, :string)
    field(:event_ref, :string)
    field(:revision, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
