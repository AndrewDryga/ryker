defmodule Responder.Slack.ChannelConfiguration do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "slack_channel_configurations" do
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:participation, Ecto.Enum, values: [:mentions, :proactive, :shadow])
    field(:repository_ref, :string)
    field(:alert_policy, Ecto.Enum, values: [:reply, :offer, :automatic])
    field(:invite_user_refs, {:array, :string}, default: [])
    field(:invite_user_group_refs, {:array, :string}, default: [])
    field(:actor_ref, :string)
    field(:revision, :integer)
    field(:saved_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
