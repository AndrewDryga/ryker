defmodule Ryker.Settings.Environment.Query do
  @moduledoc "Work environments, for every read of `environment_settings` and of who selects one."
  use Ryker, :query
  alias Ryker.Settings.Environment

  def all, do: from(environments in Environment, as: :environment_settings)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [environment_settings: e], e.ref == ^ref)

  def ordered_by_ref(queryable), do: order_by(queryable, [environment_settings: e], e.ref)

  @doc "The default environment's ref."
  def default_ref, do: from(e in all(), where: e.is_default, select: e.ref)

  @doc "Each environment as `{ref, display_name, is_default}`."
  def select_names(queryable \\ all()),
    do: select(queryable, [environment_settings: e], {e.ref, e.display_name, e.is_default})

  def with_preloaded_repositories(queryable), do: preload(queryable, :repositories)

  @doc "The default environments other than `ref`: the one a new default replaces."
  def other_defaults(ref),
    do: where(all(), [environment_settings: e], e.is_default and e.ref != ^ref)

  @doc """
  How many Slack channels choose each environment, as `{environment_ref,
  count}`, with nil for those that chose none. Channels live in the Slack
  tables, so they are read there by table name: Settings does not depend on
  Slack.
  """
  def channel_counts do
    from(configuration in "slack_channel_configurations",
      group_by: configuration.environment_ref,
      select: {configuration.environment_ref, count()}
    )
  end

  @doc "The Slack channels that select environment `ref`, read by table name the same way."
  def selecting_channels(ref) do
    from(configuration in "slack_channel_configurations",
      where: configuration.environment_ref == ^ref
    )
  end
end
