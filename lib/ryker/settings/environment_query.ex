defmodule Ryker.Settings.EnvironmentQuery do
  @moduledoc "Work environments, for every read of `environment_settings` and of who selects one."
  import Ecto.Query
  alias Ryker.Settings.Environment

  def all, do: from(environments in Environment, as: :environment_settings)

  def ordered_by_ref(queryable), do: order_by(queryable, [environment_settings: e], e.ref)
  def with_repositories(queryable), do: preload(queryable, :repositories)

  @doc "The default environments other than `ref`: the one a new default replaces."
  def other_defaults(ref),
    do: where(all(), [environment_settings: e], e.is_default and e.ref != ^ref)

  @doc """
  The Slack channels that select environment `ref`. Channels live in the
  Slack tables, so they are read there by table name: Settings does not
  depend on Slack.
  """
  def selecting_channels(ref) do
    from(configuration in "slack_channel_configurations",
      where: configuration.environment_ref == ^ref
    )
  end
end
