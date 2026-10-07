defmodule Ryker.Slack.ConfigurationSession.Query do
  @moduledoc "Conversations that set up a Slack channel, for every read of `slack_configuration_sessions`."
  import Ecto.Query
  alias Ryker.Slack.ConfigurationSession

  def all, do: from(sessions in ConfigurationSession, as: :slack_configuration_sessions)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [slack_configuration_sessions: s], s.id == ^id)

  def by_start_event(queryable \\ all(), event_ref),
    do: where(queryable, [slack_configuration_sessions: s], s.start_event_ref == ^event_ref)

  def by_channel(queryable \\ all(), workspace_ref, channel_ref) do
    where(
      queryable,
      [slack_configuration_sessions: s],
      s.workspace_ref == ^workspace_ref and s.channel_ref == ^channel_ref
    )
  end

  @doc "The setup sessions whose current prompt is message `message_ref` of a channel, latest first."
  def by_current_message(workspace_ref, channel_ref, message_ref) do
    all()
    |> by_channel(workspace_ref, channel_ref)
    |> where([slack_configuration_sessions: s], s.current_message_ref == ^message_ref)
    |> order_by([slack_configuration_sessions: s], desc: s.revision, desc: s.updated_at)
  end

  @doc "Sessions still asking or confirming."
  def active(queryable),
    do: where(queryable, [slack_configuration_sessions: s], s.status in [:asking, :confirming])

  def expired_by(queryable, now),
    do: where(queryable, [slack_configuration_sessions: s], s.expires_at <= ^now)

  def unexpired_at(queryable, now),
    do: where(queryable, [slack_configuration_sessions: s], s.expires_at > ^now)

  def ordered_by_recent(queryable),
    do: order_by(queryable, [slack_configuration_sessions: s], desc: s.inserted_at)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
