defmodule Ryker.ConversationRef do
  @moduledoc """
  The ref a Slack conversation is stored under: "slack:<workspace>:<channel>"
  for a channel or direct message, and "slack:<workspace>" for the scope of
  the workspace itself. Episodes, memories, rules, schedules and cards all key
  on it, so it is built and read in one place: forty modules wrote it out by
  hand, and about thirty read it back with splits that disagreed on a ref
  with more parts, until 2026-10-08.
  """

  @doc ~s(A Slack channel's ref: "slack:T123:C456".)
  @spec slack(String.t(), String.t()) :: String.t()
  def slack(workspace_ref, channel_ref), do: "slack:#{workspace_ref}:#{channel_ref}"

  @doc "The ref of the Slack channel something Slack sent happened in: a command, a pressed control."
  @spec slack(%{workspace_ref: String.t(), channel_ref: String.t()}) :: String.t()
  def slack(%{workspace_ref: workspace_ref, channel_ref: channel_ref}),
    do: slack(workspace_ref, channel_ref)

  @doc ~s(A Slack workspace's own scope: "slack:T123".)
  @spec slack_workspace(String.t()) :: String.t()
  def slack_workspace(workspace_ref), do: "slack:#{workspace_ref}"

  @doc ~s(What every channel ref of a workspace starts with: "slack:T123:".)
  @spec slack_prefix(String.t()) :: String.t()
  def slack_prefix(workspace_ref), do: "slack:#{workspace_ref}:"

  @doc """
  A Slack channel's ref read back: `{:ok, workspace_ref, channel_ref}`, or
  `:error` for any other ref. Neither part holds a colon, so a ref with
  anything after its channel names no channel: read as one, a write naming a
  deleted channel under such a ref passed the channel fence (2026-10-04
  review).
  """
  @spec parse_slack(term()) :: {:ok, String.t(), String.t()} | :error
  def parse_slack("slack:" <> rest) do
    case String.split(rest, ":") do
      [workspace_ref, channel_ref] when workspace_ref != "" and channel_ref != "" ->
        {:ok, workspace_ref, channel_ref}

      _other ->
        :error
    end
  end

  def parse_slack(_ref), do: :error

  @doc "The channel a Slack conversation ref names, or nil for a ref that names none."
  @spec slack_channel(term()) :: String.t() | nil
  def slack_channel(ref) do
    case parse_slack(ref) do
      {:ok, _workspace_ref, channel_ref} -> channel_ref
      :error -> nil
    end
  end
end
