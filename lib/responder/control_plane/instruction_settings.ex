defmodule Responder.ControlPlane.InstructionSettings do
  @moduledoc "Instruction controls for the existing loopback operator, never a model tool."
  import Ecto.Query
  alias Responder.Episodes.Episode
  alias Responder.Instructions
  alias Responder.Repo
  alias Responder.Slack.{ChannelConfiguration, ChannelMembership, IncidentRoom}

  def fetch(scope) do
    with {:ok, _membership} <- available(scope),
         %{scope_ref: _} = setting <- Instructions.get(scope) do
      {:ok, %{setting: setting, global: if(scope != :global, do: Instructions.get(:global))}}
    else
      _ -> {:error, :instructions_scope_unavailable}
    end
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
