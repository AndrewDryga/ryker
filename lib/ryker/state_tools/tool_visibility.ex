defmodule Ryker.StateTools.ToolVisibility do
  @moduledoc false
  alias Ryker.Episodes
  alias Ryker.Work

  @tool_transports %{
    "read_github_conversation" => MapSet.new(["github"]),
    "read_github_pull_request" => MapSet.new(["control_plane", "github", "slack"]),
    "read_github_ci" => MapSet.new(["control_plane", "github", "slack"]),
    "find_github_ci" => MapSet.new(["control_plane", "github", "slack"]),
    "search_github" => MapSet.new(["control_plane", "github", "slack"]),
    "submit_github_review" => MapSet.new(["control_plane", "github", "slack"]),
    "rerun_github_ci" => MapSet.new(["control_plane", "github", "slack"]),
    "close_github_pull_request" => MapSet.new(["control_plane", "github", "slack"]),
    "cancel_github_ci" => MapSet.new(["control_plane", "github", "slack"]),
    "set_github_reaction" => MapSet.new(["github"]),
    "list_slack_channels" => MapSet.new(["control_plane", "slack"]),
    "search_slack" => MapSet.new(["control_plane", "slack"]),
    "read_slack_source" => MapSet.new(["control_plane", "slack"]),
    "set_slack_reaction" => MapSet.new(["control_plane", "slack"]),
    "post_slack_message" => MapSet.new(["control_plane", "slack"]),
    "post_slack_update" => MapSet.new(["control_plane", "slack"])
  }

  # A GitHub reaction answers a current input, the comment it names, wherever
  # the task lives, so a current input that takes one offers it too: a comment
  # on a Slack task's own pull request may ask for one (2026-10-12). A Slack
  # reaction stays with the task's home, the channel its authority is bound to.
  @input_tools MapSet.new(["set_github_reaction"])

  @spec visible?(String.t(), String.t() | nil, :live | :shadow, [String.t()]) :: boolean()
  def visible?(name, destination_transport, mode, reaction_transports \\ [])

  def visible?(name, destination_transport, mode, reaction_transports) when is_binary(name) do
    case allowed_transports(name) do
      nil ->
        Work.Contract.platform_tool_allowed?(mode, name)

      allowed ->
        transports =
          if MapSet.member?(@input_tools, name),
            do: [destination_transport | reaction_transports],
            else: [destination_transport]

        Enum.any?(transports, &MapSet.member?(allowed, &1)) and
          Work.Contract.platform_tool_allowed?(mode, name)
    end
  end

  def visible?(_name, _destination_transport, _mode, _reaction_transports), do: false

  @doc "Where the inputs among `events` that take a reaction came from."
  @spec reaction_transports([Episodes.Event.t()]) :: [String.t()]
  def reaction_transports(events) do
    for %Episodes.Event{
          payload: %{
            "payload" => %{
              "destination" => %{"transport" => transport},
              "source_capabilities" => %{"react" => _reaction}
            }
          }
        } <- events,
        uniq: true,
        do: transport
  end

  defp allowed_transports(name), do: Map.get(@tool_transports, name)
end
