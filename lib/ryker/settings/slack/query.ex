defmodule Ryker.Settings.Slack.Query do
  @moduledoc "The installation's Slack connection, for every read of `slack_settings`."
  use Ryker, :query
  alias Ryker.Settings.Slack

  def all, do: from(settings in Slack, as: :slack_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [slack_settings: s], s.id == ^id)

  def select_workspace_url(queryable \\ all()),
    do: select(queryable, [slack_settings: s], s.workspace_url)

  @doc "How the installation's channels take part by default, as `{workspace_ref, participation}`."
  def select_default_participation(queryable \\ all()),
    do: select(queryable, [slack_settings: s], {s.workspace_ref, s.default_participation})
end
