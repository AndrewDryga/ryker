defmodule Ryker.Episodes do
  @moduledoc """
  Durable boundary for the episode state machine.

  One transaction serializes a source identity, decides its pure transition,
  and stores the projection plus immutable event. No external action runs in
  this transaction.
  """

  import Ecto.Query

  alias Ryker.Episodes.{
    Command,
    ConversationLock,
    CorrelationClaims,
    Episode,
    EpisodeChangeset,
    Event,
    EventChangeset,
    Kernel,
    Origins,
    RoutingDigests,
    Transition
  }

  alias Ryker.Repo
  alias Ryker.State.Cases
  alias Ryker.Work.Turn

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
  @spec apply_batch_in_transaction([Command.t()], keyword()) ::
          {:ok, [Transition.t()]} | {:error, term()}
  def apply_batch_in_transaction(commands, options \\ []) do
    with {:ok, commands} <- prepare_batch(commands),
         :ok <- lock_input_conversations(Repo, commands),
         episode_key <- commands |> hd() |> Map.fetch!(:episode_key),
         {:ok, :locked} <- lock_source(Repo, episode_key),
         {:ok, episode} <- load_episode(Repo, episode_key) do
      apply_prepared_batch(Repo, episode, commands, options)
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

  @doc false
  @spec lock_current_in_transaction(String.t()) :: {:ok, Episode.t()} | {:error, term()}
  def lock_current_in_transaction(episode_key) when is_binary(episode_key) do
    with {:ok, :locked} <- lock_source(Repo, episode_key),
         {:ok, %Episode{} = episode} <- load_episode(Repo, episode_key) do
      {:ok, episode}
    else
      {:ok, nil} -> {:error, :episode_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def lock_current_in_transaction(_episode_key), do: {:error, :invalid_episode_key}

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

  defp lock_input_conversations(repo, commands) do
    destinations =
      Enum.flat_map(commands, fn
        %Command.AdmitInput{destination: destination} -> [destination]
        _command -> []
      end)

    ConversationLock.lock_many(repo, destinations)
  end

  defp apply_prepared_batch(repo, episode, commands, options) do
    commands
    |> Enum.reduce_while({:ok, episode, []}, fn command, {:ok, stored, transitions} ->
      with :ok <- guard_active_work_transition(repo, stored, command, options),
           {:ok, event} <- load_existing_event(repo, stored, Command.dedupe_key(command)),
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

  defp guard_active_work_transition(
         repo,
         %Episode{} = episode,
         %{expected_owner: %{kind: :turn, ref: turn_ref}} = command,
         options
       )
       when is_struct(command, Command.CancelEpisode) or
              is_struct(command, Command.TransferOwner) do
    bound_turn_id =
      repo.one(
        from(turn in Turn,
          where:
            turn.episode_id == ^episode.id and turn.turn_ref == ^turn_ref and
              turn.status in [:pending, :cancel_pending, :blocked],
          select: turn.id
        )
      )

    case {bound_turn_id, Keyword.get(options, :settled_work_turn_id)} do
      {nil, _authorization} -> :ok
      {turn_id, turn_id} -> :ok
      {_turn_id, _authorization} -> {:error, :work_cancellation_required}
    end
  end

  defp guard_active_work_transition(_repo, _episode, _command, _options), do: :ok

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
         {:ok, event} <- persist_event(repo, transition.event, episode.id),
         :ok <- Origins.record_in_transaction(episode, event),
         :ok <- release_occurrences(episode),
         :ok <- withdraw_retained_sources(event),
         :ok <- RoutingDigests.refresh_in_transaction(episode, event) do
      {:ok, %{transition | episode: episode, event: event}}
    end
  end

  # Somebody deleting their message is a withdrawal, not expiry: every durable
  # record derived from it is redacted in the same transaction, so nothing can
  # keep quoting text that was explicitly removed.
  defp withdraw_retained_sources(%Event{kind: :input_admitted, payload: %{} = command}) do
    document = command["payload"]

    if is_map(document) and document["event_kind"] == "delete" and
         is_binary(command["native_input_id"]) do
      _redacted = Cases.withdraw_source(command["native_input_id"])
    end

    :ok
  end

  defp withdraw_retained_sources(%Event{}), do: :ok

  # The claim fences concurrent active work, not the identity forever. Once an
  # episode is finished or cancelled its occurrences are free again, so a later
  # report of the same pull request or run starts its own work instead of being
  # rejected until an operator unblocks it. The retired rows stay as history.
  defp release_occurrences(%Episode{state: state, id: id})
       when state in [:complete, :cancelled] do
    {:ok, _count} = CorrelationClaims.retire_in_transaction(id)
    :ok
  end

  defp release_occurrences(%Episode{}), do: :ok

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
