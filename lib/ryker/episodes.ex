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

  alias Ryker.Memories.Cases
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work.Turn

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
         episode_key <- commands |> hd() |> Map.fetch!(:episode_key),
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
         :ok <- close_open_questions(episode),
         :ok <- withdraw_retained_sources(event),
         :ok <- RoutingDigests.refresh_in_transaction(episode, event) do
      broadcast_episode_updated(episode)
      {:ok, %{transition | episode: episode, event: event}}
    end
  end

  # Somebody deleting their message, or editing it to say something else, is
  # a withdrawal, not expiry: every durable record derived from it is redacted
  # in the same transaction, so nothing can keep quoting text that was
  # explicitly removed. An edit that leaves the words as they were, as Slack
  # reports a link's preview arriving, withdraws nothing.
  defp withdraw_retained_sources(%Event{kind: :input_admitted, payload: %{} = command} = event) do
    if is_binary(command["native_input_id"]) and withdrawn?(event, command["payload"]) do
      _redacted = Cases.withdraw_source(command["native_input_id"])
    end

    :ok
  end

  defp withdraw_retained_sources(%Event{}), do: :ok

  defp withdrawn?(_event, %{"event_kind" => "delete"}), do: true

  defp withdrawn?(event, %{"event_kind" => "edit"} = document),
    do: replaced_words?(event, document)

  defp withdrawn?(_event, _document), do: false

  # Whether an edit says something other than the revision of the message
  # this work admitted before it. Only the text a person wrote counts, as for
  # the copies routing keeps (`Ryker.RoutingExamples`): text that cannot be
  # read, or a message with no earlier revision here, is never the same, so a
  # withdrawal errs toward erasing.
  defp replaced_words?(%Event{} = event, document) do
    earlier =
      Repo.one(
        from(stored in Event,
          where:
            stored.episode_id == ^event.episode_id and stored.kind == :input_admitted and
              stored.sequence < ^event.sequence and
              fragment("(?::jsonb)->>'native_input_id'", stored.payload) ==
                ^event.payload["native_input_id"],
          order_by: [desc: stored.sequence],
          limit: 1,
          select: fragment("(?::jsonb)#>>'{payload,content,text}'", stored.payload)
        )
      )

    case document["content"] do
      %{"text" => ^earlier} when is_binary(earlier) -> false
      _other_words -> true
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
    do: Repo.after_commit(fn -> announce_episode(episode_id) end)

  def broadcast_episode_updated(nil), do: :ok

  @doc """
  Internal — announces, after the outermost commit, that something in a
  conversation changed that no request holds yet: a message received there,
  or a choice made for the conversation itself.
  """
  @spec broadcast_conversation_updated(String.t() | nil, String.t() | nil) :: :ok
  def broadcast_conversation_updated(transport, conversation_ref)
      when is_binary(transport) and is_binary(conversation_ref),
      do: Repo.after_commit(fn -> announce_conversation(transport, conversation_ref) end)

  def broadcast_conversation_updated(_transport, _conversation_ref), do: :ok

  defp episodes_topic, do: "episodes"
  defp episode_topic(episode_id), do: "episode:#{episode_id}"
  defp conversations_topic(transport), do: "conversations:#{transport}"

  defp conversation_topic(transport, conversation_ref),
    do: "conversation:#{transport}:#{conversation_ref}"

  # A request removed by the change is still announced, so a page showing it
  # can say it is gone; it has no conversation left to announce.
  defp announce_episode(episode_id) do
    destination =
      Repo.one(
        from(episode in Episode,
          where: episode.id == ^episode_id,
          select: {episode.destination_transport, episode.destination_conversation_ref}
        )
      )

    Ryker.PubSub.broadcast(episode_topic(episode_id), {:episode_updated, episode_id})
    Ryker.PubSub.broadcast(episodes_topic(), {:episode_updated, episode_id})

    case destination do
      {transport, conversation_ref} when is_binary(transport) and is_binary(conversation_ref) ->
        announce_conversation(transport, conversation_ref)

      _none ->
        :ok
    end
  end

  defp announce_conversation(transport, conversation_ref) do
    message = {:conversation_updated, conversation_ref}
    Ryker.PubSub.broadcast(conversation_topic(transport, conversation_ref), message)
    Ryker.PubSub.broadcast(conversations_topic(transport), message)
  end
end
