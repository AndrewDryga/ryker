defmodule Ryker.Episodes do
  @moduledoc """
  Durable boundary for the episode state machine.

  One transaction serializes a source identity, decides its pure transition,
  and stores the projection plus immutable event. No external action runs in
  this transaction.

  An episode is what the control plane calls a request, and this context owns
  the topics that say one changed (`subscribe_episode/1`), and the topics that
  say a conversation's requests and messages did (`subscribe_conversation/2`).
  Every context that keeps something for a request (its work, deliveries,
  publications, records, follow-ups, Slack cards) announces it here, after its
  commit, with `broadcast_episode_updated/1`.
  """
  alias Ryker.AdvisoryLock
  alias Ryker.Episodes.{Command, ConversationLock, CorrelationClaims, Episode}
  alias Ryker.Episodes.{Event, Kernel, Origins}
  alias Ryker.Episodes.{RoutingDigests, Transition}
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

  @spec apply(Command.t()) :: {:ok, Transition.t()} | {:error, term()}
  def apply(command) do
    Repo.transaction(fn ->
      case apply_batch_in_transaction([command]) do
        {:ok, [transition]} -> transition
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  @doc """
  Applies related commands under the caller's transaction and one episode lock.

  This is used when one trusted input both enters an episode and resolves its
  current wait. The caller rolls back on an error, so either every transition
  is durable or none is.
  """
  @spec apply_batch_in_transaction([Command.t()], keyword()) ::
          {:ok, [Transition.t()]} | {:error, term()}
  def apply_batch_in_transaction(commands, options \\ []) do
    with {:ok, commands} <- prepare_batch(commands),
         :ok <- lock_input_conversations(Repo, commands),
         %{episode_key: episode_key} = hd(commands),
         {:ok, :locked} <- lock_source(Repo, episode_key),
         {:ok, episode} <- load_episode(Repo, episode_key) do
      apply_prepared_batch(Repo, episode, commands, options)
    end
  end

  # Tests read an episode back by its key; production reads go through the
  # kernel's own loads.
  @doc false
  @spec fetch_by_key(String.t()) :: {:ok, Episode.t()} | :error
  def fetch_by_key(key) do
    case Repo.fetch(Episode.Query.by_key(key)) do
      {:ok, episode} -> {:ok, episode}
      {:error, :not_found} -> :error
    end
  end

  @spec list_events(String.t()) :: [Event.t()]
  def list_events(key) do
    key |> Event.Query.by_episode_key() |> Repo.all()
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
      episode.id
      |> Work.Turn.Query.by_episode_id()
      |> Work.Turn.Query.by_turn_ref(turn_ref)
      |> Work.Turn.Query.unsettled()
      |> Work.Turn.Query.select_ids()
      |> repo.one()

    case {bound_turn_id, Keyword.get(options, :settled_work_turn_id)} do
      {nil, _authorization} -> :ok
      {turn_id, turn_id} -> :ok
      {_turn_id, _authorization} -> {:error, :work_cancellation_required}
    end
  end

  defp guard_active_work_transition(_repo, _episode, _command, _options), do: :ok

  defp lock_source(repo, episode_key) do
    case AdvisoryLock.hold(episode_key, :exclusive, repo) do
      :ok -> {:ok, :locked}
      {:error, reason} -> {:error, {:store_failed, :source_lock, reason}}
    end
  end

  defp load_episode(repo, episode_key) do
    {:ok, episode_key |> Episode.Query.by_key() |> Episode.Query.lock_for_update() |> repo.one()}
  end

  defp load_existing_event(_repo, nil, _dedupe_key), do: {:ok, nil}

  defp load_existing_event(repo, %Episode{} = episode, dedupe_key) do
    {:ok,
     episode.id
     |> Event.Query.by_episode_id()
     |> Event.Query.by_dedupe_key(dedupe_key)
     |> repo.one()}
  end

  defp persist(_repo, _stored, %Transition{status: :duplicate} = transition) do
    {:ok, transition}
  end

  defp persist(repo, stored, %Transition{status: :applied} = transition) do
    with {:ok, episode} <- persist_episode(repo, stored, transition.episode),
         {:ok, event} <- persist_event(repo, transition.event, episode.id),
         :ok <- Origins.record_in_transaction(episode, event),
         :ok <- release_occurrences(episode),
         :ok <- close_open_questions(episode),
         :ok <- RoutingDigests.refresh_in_transaction(episode, event) do
      broadcast_episode_updated(episode)
      {:ok, %{transition | episode: episode, event: event}}
    end
  end

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

  # A finished or cancelled episode asks nobody anything. Work that ends
  # without an answer takes its question with it, so the card stops offering
  # answers that could only be refused as no longer current.
  defp close_open_questions(%Episode{state: state, id: id})
       when state in [:complete, :cancelled],
       do: Records.dismiss_open_questions_in_transaction(id)

  defp close_open_questions(%Episode{}), do: :ok

  defp persist_episode(repo, nil, episode) do
    episode
    |> Episode.Changeset.insert()
    |> repo.insert()
    |> persistence_result(:episode)
  end

  defp persist_episode(repo, stored, decided) do
    stored
    |> Episode.Changeset.advance(decided)
    |> repo.update()
    |> persistence_result(:episode)
  end

  defp persist_event(repo, event, episode_id) do
    event
    |> Event.Changeset.insert(episode_id)
    |> repo.insert()
    |> persistence_result(:event)
  end

  defp persistence_result({:ok, record}, _kind), do: {:ok, record}

  defp persistence_result({:error, %Ecto.Changeset{} = changeset}, kind) do
    {:error, {:persistence_failed, kind, changeset.errors}}
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to every request's changes: `{:episode_updated,
  episode_id}` once anything recorded for a request commits, its state and
  events or anything another context keeps for it.
  """
  def subscribe_episodes, do: Ryker.PubSub.subscribe(episodes_topic())

  def unsubscribe_episodes, do: Ryker.PubSub.unsubscribe(episodes_topic())

  @doc """
  Subscribes the caller to one request's changes (`{:episode_updated,
  episode_id}`), for a page that shows that request alone.
  """
  def subscribe_episode(episode_id), do: Ryker.PubSub.subscribe(episode_topic(episode_id))

  def unsubscribe_episode(episode_id), do: Ryker.PubSub.unsubscribe(episode_topic(episode_id))

  @doc """
  Subscribes the caller to every conversation of one transport:
  `{:conversation_updated, conversation_ref}` once a message received there,
  a request addressed there or anything kept for one commits. Chat's
  conversations are the `"control_plane"` transport's.
  """
  def subscribe_conversations(transport),
    do: Ryker.PubSub.subscribe(conversations_topic(transport))

  def unsubscribe_conversations(transport),
    do: Ryker.PubSub.unsubscribe(conversations_topic(transport))

  @doc """
  Subscribes the caller to one conversation (`{:conversation_updated,
  conversation_ref}`), such as the Slack channel a channel page shows.
  """
  def subscribe_conversation(transport, conversation_ref),
    do: Ryker.PubSub.subscribe(conversation_topic(transport, conversation_ref))

  def unsubscribe_conversation(transport, conversation_ref),
    do: Ryker.PubSub.unsubscribe(conversation_topic(transport, conversation_ref))

  @doc """
  Internal — announces, after the outermost commit, that something recorded
  for a request changed. Takes the episode or its id; either way the
  conversation it is addressed to is read once the change has committed, so
  the same request announced several times in one transaction, by any of the
  contexts that keep something for it, is announced once.
  """
  @spec broadcast_episode_updated(Episode.t() | Ecto.UUID.t() | nil) :: :ok
  def broadcast_episode_updated(%Episode{id: id}) when is_binary(id),
    do: broadcast_episode_updated(id)

  def broadcast_episode_updated(episode_id) when is_binary(episode_id),
    do: Repo.after_commit(fn -> broadcast_committed_episode(episode_id) end)

  def broadcast_episode_updated(nil), do: :ok

  @doc """
  Internal — announces, after the outermost commit, that something in a
  conversation changed that no request holds yet: a message received there,
  or a choice made for the conversation itself.
  """
  @spec broadcast_conversation_updated(String.t() | nil, String.t() | nil) :: :ok
  def broadcast_conversation_updated(transport, conversation_ref)
      when is_binary(transport) and is_binary(conversation_ref) do
    Repo.after_commit(fn -> broadcast_committed_conversation(transport, conversation_ref) end)
  end

  def broadcast_conversation_updated(_transport, _conversation_ref), do: :ok

  defp episodes_topic, do: "episodes"
  defp episode_topic(episode_id), do: "episode:#{episode_id}"
  defp conversations_topic(transport), do: "conversations:#{transport}"

  defp conversation_topic(transport, conversation_ref),
    do: "conversation:#{transport}:#{conversation_ref}"

  # A request removed by the change is still announced, so a page showing it
  # can say it is gone; it has no conversation left to announce.
  defp broadcast_committed_episode(episode_id) do
    destination =
      episode_id |> Episode.Query.by_id() |> Episode.Query.select_destinations() |> Repo.one()

    Ryker.PubSub.broadcast(episode_topic(episode_id), {:episode_updated, episode_id})
    Ryker.PubSub.broadcast(episodes_topic(), {:episode_updated, episode_id})

    case destination do
      {transport, conversation_ref} when is_binary(transport) and is_binary(conversation_ref) ->
        broadcast_committed_conversation(transport, conversation_ref)

      _none ->
        :ok
    end
  end

  defp broadcast_committed_conversation(transport, conversation_ref) do
    message = {:conversation_updated, conversation_ref}
    Ryker.PubSub.broadcast(conversation_topic(transport, conversation_ref), message)
    Ryker.PubSub.broadcast(conversations_topic(transport), message)
  end

  # -- For the console ---------------------------------------------------------

  @doc "A request's state, decision or stored name in the words every surface uses."
  @spec label(term()) :: String.t()
  defdelegate label(value), to: Ryker.Episodes.Words
end
