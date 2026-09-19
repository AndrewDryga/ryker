defmodule Ryker.StateTools.ToolVisibility do
  @moduledoc false

  alias Ryker.Work.Contract

  @tool_transports %{
    "read_github_conversation" => MapSet.new(["github"]),
    "search_github" => MapSet.new(["github"]),
    "set_github_reaction" => MapSet.new(["github"]),
    "list_slack_channels" => MapSet.new(["control_plane", "slack"]),
    "search_slack" => MapSet.new(["control_plane", "slack"]),
    "read_slack_source" => MapSet.new(["control_plane", "slack"]),
    "set_slack_reaction" => MapSet.new(["control_plane", "slack"]),
    "post_slack_message" => MapSet.new(["control_plane", "slack"])
  }

  @spec visible?(String.t(), String.t() | nil) :: boolean()
  def visible?(name, destination_transport), do: visible?(name, destination_transport, :live)

  @spec visible?(String.t(), String.t() | nil, :live | :shadow) :: boolean()
  def visible?(name, destination_transport, mode) when is_binary(name) do
    case allowed_transports(name) do
      nil ->
        Contract.platform_tool_allowed?(mode, name)

      allowed ->
        MapSet.member?(allowed, destination_transport) and
          Contract.platform_tool_allowed?(mode, name)
    end
  end

  def visible?(_name, _destination_transport, _mode), do: false

  defp allowed_transports(name), do: Map.get(@tool_transports, name)
end
