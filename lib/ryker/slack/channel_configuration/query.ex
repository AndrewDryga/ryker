defmodule Ryker.Slack.ChannelConfiguration.Query do
  @moduledoc "How each Slack channel is set up for Ryker, for every read of `slack_channel_configurations`."
  import Ecto.Query
  alias Ryker.Slack.ChannelConfiguration

  def all, do: from(configurations in ChannelConfiguration, as: :slack_channel_configurations)

  def by_channel(queryable \\ all(), workspace_ref, channel_ref) do
    where(
      queryable,
      [slack_channel_configurations: c],
      c.workspace_ref == ^workspace_ref and c.channel_ref == ^channel_ref
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
