defmodule Ryker.Slack.ChannelMembership.Query do
  @moduledoc "The Slack channels Ryker is in, for every read of `slack_channel_memberships`."
  use Ryker, :query
  alias Ryker.Slack.ChannelMembership

  def all, do: from(memberships in ChannelMembership, as: :slack_channel_memberships)

  def by_channel(queryable \\ all(), workspace_ref, channel_ref) do
    where(
      queryable,
      [slack_channel_memberships: m],
      m.workspace_ref == ^workspace_ref and m.channel_ref == ^channel_ref
    )
  end

  @doc """
  The conversations of Slack workspace `slack:<workspace>` that share what
  was learned in them with its other public channels: joined, neither
  private nor shared with another organisation, as their conversation refs.
  """
  def public_conversation_refs("slack:" <> workspace) do
    from(m in all(),
      where:
        m.workspace_ref == ^workspace and m.status == :joined and m.private == false and
          m.external_shared == false,
      select: fragment("'slack:' || ? || ':' || ?", m.workspace_ref, m.channel_ref)
    )
  end

  @doc """
  The memberships of the Slack conversations `conversation_refs` names, as
  `{conversation_ref, {status, private, external_shared}}`, in key order.
  """
  def by_conversation_refs(conversation_refs) do
    from(m in all(),
      where:
        fragment("'slack:' || ? || ':' || ?", m.workspace_ref, m.channel_ref) in ^conversation_refs,
      order_by: [asc: m.workspace_ref, asc: m.channel_ref],
      select:
        {fragment("'slack:' || ? || ':' || ?", m.workspace_ref, m.channel_ref),
         {m.status, m.private, m.external_shared}}
    )
  end

  def by_id(queryable \\ all(), id),
    do: where(queryable, [slack_channel_memberships: m], m.id == ^id)

  def by_workspace(queryable \\ all(), workspace_ref),
    do: where(queryable, [slack_channel_memberships: m], m.workspace_ref == ^workspace_ref)

  def joined(queryable), do: where(queryable, [slack_channel_memberships: m], m.status == :joined)

  def updated_by(queryable, at),
    do: where(queryable, [slack_channel_memberships: m], m.updated_at <= ^at)

  def excluding_channels(queryable, channel_refs),
    do: where(queryable, [slack_channel_memberships: m], m.channel_ref not in ^channel_refs)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  @doc "Each membership's status and who may read its channel: `{status, private, external_shared}`."
  def select_audience(queryable) do
    select(
      queryable,
      [slack_channel_memberships: m],
      {m.status, m.private, m.external_shared}
    )
  end

  def ordered_by_channel(queryable),
    do: order_by(queryable, [slack_channel_memberships: m], asc: m.channel_ref)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def select_statuses(queryable),
    do: select(queryable, [slack_channel_memberships: m], m.status)

  def select_privacy(queryable),
    do: select(queryable, [slack_channel_memberships: m], {m.private, m.external_shared})

  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")

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
