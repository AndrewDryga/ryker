defmodule Ryker.Slack.ChannelMembershipQuery do
  @moduledoc "The Slack channels Ryker is in, for every read of `slack_channel_memberships`."
  import Ecto.Query
  alias Ryker.Slack.ChannelMembership

  def all, do: from(memberships in ChannelMembership, as: :slack_channel_memberships)

  def by_channel(queryable \\ all(), workspace_ref, channel_ref) do
    where(
      queryable,
      [slack_channel_memberships: m],
      m.workspace_ref == ^workspace_ref and m.channel_ref == ^channel_ref
    )
  end

  @doc "Each deleted channel in `workspace_refs`, as `{workspace, channel}`."
  def deleted_in_workspaces(workspace_refs) do
    all()
    |> where(
      [slack_channel_memberships: m],
      m.workspace_ref in ^workspace_refs and m.status == :deleted
    )
    |> select([slack_channel_memberships: m], {m.workspace_ref, m.channel_ref})
  end

  @doc "Joined channels anyone in the workspace can read: public and not shared with another organisation."
  def joined_public(queryable \\ all()) do
    where(
      queryable,
      [slack_channel_memberships: m],
      m.status == :joined and m.private == false and m.external_shared == false
    )
  end
end
