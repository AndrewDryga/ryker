defmodule Ryker.Settings.EnvironmentQuery do
  @moduledoc "Work environments, for every read of `environment_settings` and of who selects one."
  import Ecto.Query

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
