defmodule Ryker.Slack.ChannelMembership.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Slack.ChannelMembership

  @fields [
    :channel_ref,
    :deleted_at,
    :external_shared,
    :generation,
    :id,
    :joined_at,
    :left_at,
    :private,
    :status,
    :workspace_ref
  ]

  def insert(attributes) do
    %ChannelMembership{}
    |> cast(attributes, @fields)
    |> validate_required([:channel_ref, :generation, :id, :status, :workspace_ref])
    |> unique_constraint(:channel_ref,
      name: :slack_channel_memberships_workspace_ref_channel_ref_index
    )
    |> check_constraint(:status, name: :slack_channel_membership_valid)
  end

  def update(%ChannelMembership{} = membership, attributes) do
    membership
    |> cast(attributes, [
      :deleted_at,
      :external_shared,
      :generation,
      :joined_at,
      :left_at,
      :private,
      :status
    ])
    |> validate_required([:generation, :status])
    |> check_constraint(:status, name: :slack_channel_membership_valid)
  end
end
