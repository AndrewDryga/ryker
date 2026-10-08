defmodule Ryker.Slack.ChannelMembershipEvent.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Slack.ChannelMembershipEvent

  @fields [
    :actor_ref,
    :channel_ref,
    :event_fingerprint,
    :event_ref,
    :id,
    :kind,
    :membership_id,
    :occurred_at,
    :workspace_ref
  ]

  def insert(attributes) do
    %ChannelMembershipEvent{}
    |> cast(attributes, @fields)
    |> validate_required(@fields -- [:actor_ref])
    |> unique_constraint(:event_ref,
      name: :slack_channel_membership_events_workspace_ref_event_ref_index
    )
    |> check_constraint(:kind, name: :slack_channel_membership_event_valid)
  end
end
