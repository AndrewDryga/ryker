defmodule Ryker.ControlPlane.InstructionSettings do
  @moduledoc "Instruction controls for a console person, never a model tool."
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Instructions
  alias Ryker.Repo
  alias Ryker.Slack

  @doc """
  The saved instructions for `scope`. The global view also carries every
  channel that adds instructions of its own, which the Instructions page lists
  under its editor.
  """
  def fetch(scope) do
    with {:ok, _membership} <- available(scope),
         {:ok, setting} <- Instructions.get(scope) do
      {:ok, view(scope, setting)}
    else
      _ -> {:error, :instructions_scope_unavailable}
    end
  end

  defp view(:global, setting), do: %{setting: setting, channels: channels()}
  defp view(_channel, setting), do: %{setting: setting}

  # A cleared channel has nothing to add, so it is not listed.
  @channel_limit 500
  defp channels do
    Instructions.Setting.Query.all()
    |> Instructions.Setting.Query.for_slack_channels()
    |> Instructions.Setting.Query.having_text()
    |> Instructions.Setting.Query.ordered_by_scope()
    |> Instructions.Setting.Query.limit_to(@channel_limit)
    |> Repo.all()
    |> Enum.flat_map(fn setting ->
      case ConversationRef.parse_slack(setting.scope_ref) do
        {:ok, workspace, channel} ->
          [%{workspace_ref: workspace, channel_ref: channel, text: setting.text}]

        _other ->
          []
      end
    end)
  end

  @doc """
  Saves the instructions for `scope` at `revision` as `actor_ref` wrote them. A
  channel Ryker left or Slack deleted keeps no new instructions, only an empty
  save that clears them.
  """
  def save(scope, text, revision, actor_ref) do
    with {:ok, membership} <- available(scope),
         {:ok, text} <- Instructions.normalize_text(text) do
      if membership in [:left, :deleted] and text != "",
        do: {:error, :instructions_scope_unavailable},
        else: Instructions.save(scope, text, revision, actor_ref)
    end
  end

  defp available(:global), do: {:ok, nil}

  defp available({:channel, workspace, channel})
       when is_binary(workspace) and is_binary(channel) and
              byte_size(workspace) <= 256 and byte_size(channel) <= 256 do
    membership =
      workspace
      |> Slack.ChannelMembership.Query.by_channel(channel)
      |> Slack.ChannelMembership.Query.select_statuses()
      |> Repo.one()

    if membership || known_channel?(workspace, channel),
      do: {:ok, membership},
      else: {:error, :instructions_scope_unavailable}
  end

  defp available(_), do: {:error, :instructions_scope_unavailable}

  defp known_channel?(workspace, channel) do
    Repo.exists?(Slack.ChannelConfiguration.Query.by_channel(workspace, channel)) or
      Repo.exists?(Slack.IncidentRoom.Query.by_channel(workspace, channel)) or
      Repo.exists?(
        Episodes.Episode.Query.by_conversation("slack", ConversationRef.slack(workspace, channel))
      )
  end
end
