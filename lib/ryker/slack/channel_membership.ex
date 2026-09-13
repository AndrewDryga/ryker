defmodule Ryker.Slack.ChannelMembership do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "slack_channel_memberships" do
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:external_shared, :boolean)
    field(:private, :boolean)
    field(:status, Ecto.Enum, values: [:joined, :left, :deleted])
    field(:generation, :integer)
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
