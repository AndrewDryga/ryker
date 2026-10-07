defmodule Ryker.Slack.ChannelMembershipEvent do
  @moduledoc false
  use Ryker, :schema

  schema "slack_channel_membership_events" do
    belongs_to(:membership, Ryker.Slack.ChannelMembership)
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:event_ref, :string)
    field(:event_fingerprint, :string)
    field(:actor_ref, :string)
    field(:kind, Ecto.Enum, values: [:joined, :left, :deleted])
    field(:occurred_at, :utc_datetime_usec)
    timestamps(updated_at: false)
  end
end
