defmodule Ryker.Slack.ChannelSettingAudit.Query do
  @moduledoc "Channel setting changes made from Slack, for every read of `slack_channel_setting_audit`."
  import Ecto.Query
  alias Ryker.Slack.ChannelSettingAudit

  def all, do: from(audits in ChannelSettingAudit, as: :slack_channel_setting_audit)

  def by_event_ref(queryable \\ all(), event_ref),
    do: where(queryable, [slack_channel_setting_audit: a], a.event_ref == ^event_ref)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
