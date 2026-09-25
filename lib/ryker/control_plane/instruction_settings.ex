defmodule Ryker.ControlPlane.InstructionSettings do
  @moduledoc "Instruction controls for the existing loopback operator, never a model tool."
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Instructions
  alias Ryker.Instructions.Setting
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfiguration, ChannelMembership, IncidentRoom}

  @doc """
  The saved instructions for `scope`. A channel's view carries the global
  text it inherits; the global view carries every channel that adds
  instructions of its own, which the Instructions page lists under its editor.
  """
  def fetch(scope) do
    with {:ok, _membership} <- available(scope),
         %{scope_ref: _} = setting <- Instructions.get(scope) do
      {:ok, view(scope, setting)}
    else
      _ -> {:error, :instructions_scope_unavailable}
    end
  end

  defp view(:global, setting), do: %{setting: setting, global: nil, channels: channels()}
  defp view(_channel, setting), do: %{setting: setting, global: Instructions.get(:global)}

  # A cleared channel has nothing to add, so it is not listed.
  @channel_limit 500
  defp channels do
    Repo.all(
      from(s in Setting,
        where: like(s.scope_ref, "slack:%") and s.text != "",
        order_by: s.scope_ref,
        limit: @channel_limit
      )
    )
    |> Enum.flat_map(fn setting ->
      case String.split(setting.scope_ref, ":") do
        ["slack", workspace, channel] ->
          [%{workspace_ref: workspace, channel_ref: channel, text: setting.text}]

        _other ->
          []
      end
    end)
  end

  def save(scope, text, revision) do
    with {:ok, membership} <- available(scope),
         {:ok, text} <- Instructions.normalize_text(text) do
      if membership in [:left, :deleted] and text != "",
        do: {:error, :instructions_scope_unavailable},
        else: Instructions.save(scope, text, revision, "control-plane:local")
    end
  end

  defp available(:global), do: {:ok, nil}

  defp available({:channel, workspace, channel})
       when is_binary(workspace) and is_binary(channel) and
              byte_size(workspace) <= 256 and byte_size(channel) <= 256 do
    membership =
      Repo.one(
        from(m in ChannelMembership,
          where: m.workspace_ref == ^workspace and m.channel_ref == ^channel,
          select: m.status
        )
      )

    if membership || known_channel?(workspace, channel),
      do: {:ok, membership},
      else: {:error, :instructions_scope_unavailable}
  end

  defp available(_), do: {:error, :instructions_scope_unavailable}

  defp known_channel?(workspace, channel) do
    configured =
      Enum.any?([ChannelConfiguration, IncidentRoom], fn schema ->
        Repo.exists?(
          from(c in schema,
            where: c.workspace_ref == ^workspace and c.channel_ref == ^channel
          )
        )
      end)

    configured or
      Repo.exists?(
        from(e in Episode,
          where:
            e.destination_transport == "slack" and
              e.destination_conversation_ref == ^"slack:#{workspace}:#{channel}"
        )
      )
  end
end
