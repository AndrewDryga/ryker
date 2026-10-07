defmodule Ryker.Slack.ChannelMembershipEvent.Query do
  @moduledoc "Slack events that changed Ryker's channel memberships, for every read of `slack_channel_membership_events`."
  import Ecto.Query
  alias Ryker.Slack.ChannelMembershipEvent

  def all, do: from(events in ChannelMembershipEvent, as: :slack_channel_membership_events)

  @doc "Slack event `event_ref` of workspace `workspace_ref`."
  def by_event(workspace_ref, event_ref) do
    where(
      all(),
      [slack_channel_membership_events: e],
      e.workspace_ref == ^workspace_ref and e.event_ref == ^event_ref
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
