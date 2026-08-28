defmodule Responder.Episodes do
  @moduledoc """
  Durable boundary for the episode state machine.

  One transaction serializes a source identity, decides its pure transition,
  and stores the projection plus immutable event. No external action runs in
  this transaction.
  """

  import Ecto.Query

  alias Responder.Episodes.{
    Command,
    Episode,
    EpisodeChangeset,
    Event,
    EventChangeset,
    Kernel,
    Transition
  }

  alias Responder.Repo

  @spec apply(Command.t()) :: {:ok, Transition.t()} | {:error, term()}
  def apply(command) do
    case apply_batch([command]) do
      {:ok, [transition]} -> {:ok, transition}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies related commands under one episode lock and one database transaction.

  This is used when one trusted input both enters an episode and resolves its
  current wait. Either every transition is durable or none is.
  """
  @spec apply_batch([Command.t()]) :: {:ok, [Transition.t()]} | {:error, term()}
  def apply_batch(commands) do
    Repo.transaction(fn ->
      case apply_batch_in_transaction(commands) do
        {:ok, transitions} -> transitions
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  @doc false
  @spec apply_batch_in_transaction([Command.t()]) ::
          {:ok, [Transition.t()]} | {:error, term()}
  def apply_batch_in_transaction(commands) do
    with {:ok, commands} <- prepare_batch(commands),
         episode_key <- commands |> hd() |> Map.fetch!(:episode_key),
         {:ok, :locked} <- lock_source(Repo, episode_key),
         {:ok, episode} <- load_episode(Repo, episode_key) do
      apply_prepared_batch(Repo, episode, commands)
    end
  end

  @spec fetch_by_key(String.t()) :: {:ok, Episode.t()} | :error
  def fetch_by_key(key) do
    case Repo.one(from(episode in Episode, where: episode.key == ^key)) do
      nil -> :error
      episode -> {:ok, episode}
    end
  end

  @spec list_events(String.t()) :: [Event.t()]
  def list_events(key) do
    Repo.all(
      from(event in Event,
        join: episode in assoc(event, :episode),
        where: episode.key == ^key,
        order_by: event.sequence
      )
    )
  end

  defp prepare_batch([]), do: {:error, :empty_command_batch}

  defp prepare_batch(commands) when is_list(commands) do
    commands
    |> Enum.reduce_while({:ok, []}, fn command, {:ok, prepared} ->
      case Command.prepare(command) do
        {:ok, command} -> {:cont, {:ok, [command | prepared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} -> prepared |> Enum.reverse() |> same_episode_batch()
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_batch(_commands), do: {:error, :invalid_command_batch}

  defp same_episode_batch([first | rest] = commands) do
    if Enum.all?(rest, &(&1.episode_key == first.episode_key)),
      do: {:ok, commands},
      else: {:error, :mixed_episode_command_batch}
  end

  defp apply_prepared_batch(repo, episode, commands) do
    commands
    |> Enum.reduce_while({:ok, episode, []}, fn command, {:ok, stored, transitions} ->
      with {:ok, event} <- load_existing_event(repo, stored, Command.dedupe_key(command)),
           {:ok, transition} <- Kernel.apply(stored, event, command),
           {:ok, transition} <- persist(repo, stored, transition) do
        {:cont, {:ok, transition.episode, [transition | transitions]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _episode, transitions} -> {:ok, Enum.reverse(transitions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_source(repo, episode_key) do
    case repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [episode_key]) do
      {:ok, _result} -> {:ok, :locked}
      {:error, reason} -> {:error, {:store_failed, :source_lock, reason}}
    end
  end

  defp load_episode(repo, episode_key) do
    {:ok,
     repo.one(
       from(episode in Episode,
         where: episode.key == ^episode_key,
         lock: "FOR UPDATE"
       )
     )}
  end

  defp load_existing_event(_repo, nil, _dedupe_key), do: {:ok, nil}

  defp load_existing_event(repo, %Episode{} = episode, dedupe_key) do
    {:ok,
     repo.one(
       from(event in Event,
         where: event.episode_id == ^episode.id and event.dedupe_key == ^dedupe_key
       )
     )}
  end

  defp persist(_repo, _stored, %Transition{status: :duplicate} = transition) do
    {:ok, transition}
  end

  defp persist(repo, stored, %Transition{status: :applied} = transition) do
    with {:ok, episode} <- persist_episode(repo, stored, transition.episode),
         {:ok, event} <- persist_event(repo, transition.event, episode.id) do
      {:ok, %{transition | episode: episode, event: event}}
    end
  end

  defp persist_episode(repo, nil, episode) do
    episode
    |> EpisodeChangeset.insert()
    |> repo.insert()
    |> persistence_result(:episode)
  end

  defp persist_episode(repo, stored, decided) do
    stored
    |> EpisodeChangeset.advance(decided)
    |> repo.update()
    |> persistence_result(:episode)
  end

  defp persist_event(repo, event, episode_id) do
    event
    |> EventChangeset.insert(episode_id)
    |> repo.insert()
    |> persistence_result(:event)
  end

  defp persistence_result({:ok, record}, _kind), do: {:ok, record}

  defp persistence_result({:error, %Ecto.Changeset{} = changeset}, kind) do
    {:error, {:persistence_failed, kind, changeset.errors}}
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
