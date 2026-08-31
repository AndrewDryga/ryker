defmodule Responder.Slack.ChannelMembershipEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "slack_channel_membership_events" do
    belongs_to(:membership, Responder.Slack.ChannelMembership)
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:event_ref, :string)
    field(:event_fingerprint, :string)
    field(:actor_ref, :string)
    field(:kind, Ecto.Enum, values: [:joined, :left, :deleted])
    field(:occurred_at, :utc_datetime_usec)
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
