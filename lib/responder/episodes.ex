defmodule Responder.Episodes do
  @moduledoc """
  Durable boundary for the episode state machine.

  One transaction serializes a source identity, decides its pure transition,
  and stores the projection plus immutable event. No external action runs in
  this transaction.
  """

  import Ecto.Query

  alias Ecto.Multi

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
    with {:ok, command} <- Command.prepare(command) do
      command
      |> apply_multi()
      |> Repo.transaction()
      |> transaction_result()
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

  defp apply_multi(command) do
    Multi.new()
    |> Multi.run(:source_lock, fn repo, _changes -> lock_source(repo, command.episode_key) end)
    |> Multi.run(:episode, fn repo, _changes -> load_episode(repo, command.episode_key) end)
    |> Multi.run(:existing_event, fn repo, %{episode: episode} ->
      load_existing_event(repo, episode, Command.dedupe_key(command))
    end)
    |> Multi.run(:transition, fn _repo, %{episode: episode, existing_event: event} ->
      Kernel.apply(episode, event, command)
    end)
    |> Multi.run(:persist, fn repo, %{episode: stored, transition: transition} ->
      persist(repo, stored, transition)
    end)
  end

  defp lock_source(repo, episode_key) do
    case repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [episode_key]) do
      {:ok, _result} -> {:ok, :locked}
      {:error, reason} -> {:error, reason}
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

  defp transaction_result({:ok, %{persist: transition}}), do: {:ok, transition}
  defp transaction_result({:error, :transition, reason, _changes}), do: {:error, reason}
  defp transaction_result({:error, :persist, reason, _changes}), do: {:error, reason}

  defp transaction_result({:error, operation, reason, _changes}) do
    {:error, {:store_failed, operation, reason}}
  end
end
