defmodule Ryker.Settings.SlackQuery do
  @moduledoc "The installation's Slack connection, for every read of `slack_settings`."
  import Ecto.Query
  alias Ryker.Settings.Slack

  def all, do: from(settings in Slack, as: :slack_settings)

  def select_connection(queryable \\ all()),
    do: select(queryable, [slack_settings: s], map(s, [:enabled, :workspace_ref]))
end
