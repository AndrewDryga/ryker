defmodule Ryker.GitHub.CIRepairStop do
  @moduledoc "Revokes publication first, then asks existing Work custody to stop without discarding work."
  alias Ryker.Episodes
  alias Ryker.GitHub.CIRepairRound
  alias Ryker.Ingress
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

  def request(%{stop: false}), do: :ok

  def request(%{round: %CIRepairRound{} = round, repair: repair}) do
    case Repo.fetch(Ingress.Inbox.Entry.Query.by_id(round.entry_id)) do
      {:ok, entry} -> stop_episodes(entry, repair)
      {:error, :not_found} -> :ok
    end
  end

  defp stop_episodes(%{episode_id: nil}, _repair), do: :ok

  defp stop_episodes(entry, repair) do
    task_id =
      case Repo.fetch(Records.Record.Query.for_source_entry(entry)) do
        {:ok, record} -> record.confirmed_episode_id
        {:error, :not_found} -> nil
      end

    [entry.episode_id, task_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case stop_episode(id, repair) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stop_episode(id, repair) do
    case Repo.fetch(Episodes.Episode.Query.by_id(id)) do
      {:ok, %{state: :working, owner_kind: :turn} = episode} ->
        case Work.Custody.request_stop(
               id,
               episode.key,
               episode.owner_ref,
               "ci-repair-stop:#{repair.current_round_id}:#{id}",
               "Automatic CI repair is no longer authorized for this PR. The saved work is retained."
             ) do
          {:ok, _stopped} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _quiescent ->
        :ok
    end
  end
end
