defmodule Ryker.Settings.SlackQuery do
  @moduledoc "The installation's Slack connection, for every read of `slack_settings`."
  import Ecto.Query
  alias Ryker.Settings.Slack

  def all, do: from(settings in Slack, as: :slack_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [slack_settings: s], s.id == ^id)

  def select_workspace_url(queryable \\ all()),
    do: select(queryable, [slack_settings: s], s.workspace_url)

  @doc "Who may manage Ryker from Slack: the people chosen by name, and whether workspace admins may."
  def select_operators(queryable \\ all()) do
    select(queryable, [slack_settings: s], %{
      chosen: s.operators,
      workspace_admins: s.workspace_admins_manage,
      workspace_ref: s.workspace_ref
    })
  end

  def select_connection(queryable \\ all()),
    do: select(queryable, [slack_settings: s], map(s, [:enabled, :workspace_ref]))

  @doc "How the installation's channels take part by default, as `{workspace_ref, participation}`."
  def select_default_participation(queryable \\ all()),
    do: select(queryable, [slack_settings: s], {s.workspace_ref, s.default_participation})
end
