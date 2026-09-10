defmodule Responder.ControlPlane.InstructionSettings do
  @moduledoc "Instruction controls for the existing loopback operator, never a model tool."
  alias Responder.ControlPlane.OperatorProjection
  alias Responder.Instructions

  def fetch(scope) do
    with :ok <- available(scope),
         %{scope_ref: _} = setting <- Instructions.get(scope) do
      {:ok, %{setting: setting, global: if(scope != :global, do: Instructions.get(:global))}}
    else
      _ -> {:error, :instructions_scope_unavailable}
    end
  end

  def save(scope, text, revision) do
    with :ok <- available(scope) do
      Instructions.save(scope, text, revision, "control-plane:local")
    end
  end

  defp available(:global), do: :ok

  defp available({:channel, workspace, channel}) do
    case OperatorProjection.channel(workspace, channel) do
      {:ok, %{channel: %{membership: membership}}} when membership not in [:left, :deleted] -> :ok
      _ -> {:error, :instructions_scope_unavailable}
    end
  end

  defp available(_), do: {:error, :instructions_scope_unavailable}
end
