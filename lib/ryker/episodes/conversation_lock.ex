defmodule Ryker.Episodes.ConversationLock do
  @moduledoc false
  alias Ryker.AdvisoryLock

  @spec lock(map()) :: :ok | {:error, term()}
  def lock(destination), do: lock_many([destination])

  @spec lock_many([map()]) :: :ok | {:error, term()}
  def lock_many(destinations) do
    destinations
    |> Enum.map(&key/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case AdvisoryLock.hold(key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:store_failed, :conversation_lock, reason}}}
      end
    end)
  end

  defp key(destination) do
    "ingress-admission:#{destination.transport}:#{destination.conversation_ref}"
  end
end
