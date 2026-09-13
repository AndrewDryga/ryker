defmodule Ryker.Episodes.ConversationLock do
  @moduledoc false

  @spec lock(Ecto.Repo.t(), map()) :: :ok | {:error, term()}
  def lock(repo, destination) do
    case repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
           [key(destination)]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:store_failed, :conversation_lock, reason}}
    end
  end

  @spec lock_many(Ecto.Repo.t(), [map()]) :: :ok | {:error, term()}
  def lock_many(repo, destinations) do
    destinations
    |> Enum.map(&key/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key]) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:store_failed, :conversation_lock, reason}}}
      end
    end)
  end

  defp key(destination) do
    "ingress-admission:#{destination.transport}:#{destination.conversation_ref}"
  end
end
