defmodule Responder.Episodes.Origins do
  @moduledoc """
  Per-message origin projection of the episode ledger.

  Every `input_admitted` event records where its input came from. The
  projection is written in the same transaction as the event and is rebuilt
  from the ledger until an audited correction moves an input; it never invents
  native provenance a source did not supply. A Slack root binds its own timestamp as thread, so root and reply
  are told apart from the retained identities alone.
  """

  import Ecto.Query

  alias Responder.Episodes.{Episode, Event, Origin}
  alias Responder.Repo

  @type destination :: %{
          conversation_ref: String.t(),
          thread_ref: String.t() | nil,
          transport: String.t()
        }

  @doc "Derives the origin facts of one input document (the admitted command payload)."
  @spec from_input_document(map()) :: map()
  def from_input_document(%{"destination" => %{} = destination} = document) do
    source_kind = get_in(document, ["source", "kind"])
    source_item_ref = document["source_item_ref"]
    thread_ref = destination["thread_ref"]
    {origin_kind, root_ref} = origin_kind(source_kind, source_item_ref, thread_ref)

    %{
      transport: destination["transport"],
      conversation_ref: destination["conversation_ref"],
      thread_ref: thread_ref,
      origin_kind: origin_kind,
      root_ref: root_ref,
      source_kind: source_kind,
      source_ref: get_in(document, ["source", "ref"]),
      source_item_ref: source_item_ref
    }
  end

  @doc false
  @spec record_in_transaction(Episode.t(), Event.t()) :: :ok | {:error, term()}
  def record_in_transaction(%Episode{id: episode_id}, %Event{kind: :input_admitted} = event) do
    attributes = event |> from_event() |> Map.put(:episode_id, episode_id)

    case Repo.insert(struct!(Origin, attributes),
           on_conflict: :nothing,
           conflict_target: [:episode_id, :input_ref]
         ) do
      {:ok, _origin} -> :ok
      {:error, changeset} -> {:error, {:persistence_failed, :episode_origin, changeset.errors}}
    end
  end

  def record_in_transaction(_episode, _event), do: :ok

  @doc "Origin facts of one admitted-input event, preferring the input's own destination."
  @spec from_event(Event.t()) :: map()
  def from_event(%Event{payload: %{} = command} = event) do
    document = command["payload"]

    origin =
      if is_map(document) and is_map(document["destination"]),
        do: from_input_document(document),
        else: %{
          transport: get_in(command, ["destination", "transport"]),
          conversation_ref: get_in(command, ["destination", "conversation_ref"]),
          thread_ref: get_in(command, ["destination", "thread_ref"]),
          origin_kind: :conversation,
          root_ref: nil,
          source_kind: nil,
          source_ref: nil,
          source_item_ref: nil
        }

    Map.merge(origin, %{
      input_ref: event.dedupe_key,
      sequence: event.sequence,
      native_input_id: command["native_input_id"],
      revision: command["revision"],
      actor_ref: command["actor_ref"],
      occurred_at: event.occurred_at,
      effective: true,
      correction_ref: nil
    })
  end

  @doc """
  The episode's effective membership, in source chronology.

  An input an audited correction moved elsewhere keeps its row here, marked
  ineffective and pointing at that correction, but it is no longer this
  episode's evidence. Ordering by occurrence rather than by this episode's own
  event sequence keeps merged evidence in the order it actually happened.
  """
  @spec for_episode(Ecto.UUID.t()) :: [Origin.t()]
  def for_episode(episode_id) do
    Repo.all(
      from(origin in Origin,
        where: origin.episode_id == ^episode_id and origin.effective,
        order_by: [asc: origin.occurred_at, asc: origin.sequence]
      )
    )
  end

  @doc """
  The episode's one progress home.

  Adding evidence from another conversation never moves it: default progress
  updates have exactly one destination, so new origins cannot subscribe every
  contributing channel to repeated status and final replies.
  """
  @spec home(Episode.t()) :: destination()
  def home(%Episode{} = episode) do
    %{
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }
  end

  @doc "Where a direct answer to this input belongs."
  @spec reply_target(Origin.t()) :: destination()
  def reply_target(%Origin{} = origin) do
    %{
      conversation_ref: origin.conversation_ref,
      thread_ref: origin.thread_ref,
      transport: origin.transport
    }
  end

  @spec participating_conversations(Ecto.UUID.t()) :: [String.t()]
  def participating_conversations(episode_id) do
    Repo.all(
      from(origin in Origin,
        where: origin.episode_id == ^episode_id and origin.effective,
        distinct: true,
        order_by: [asc: origin.conversation_ref],
        select: origin.conversation_ref
      )
    )
  end

  @doc "The effective owner of one exact source item, by highest admitted revision."
  @spec current_owner(String.t(), String.t(), :live | :shadow) ::
          {Episode.t(), pos_integer()} | nil
  def current_owner(native_input_id, transport, execution_mode) do
    Repo.one(
      from(origin in Origin,
        join: episode in Episode,
        on: episode.id == origin.episode_id,
        where:
          origin.native_input_id == ^native_input_id and origin.transport == ^transport and
            origin.effective and episode.execution_mode == ^execution_mode,
        order_by: [desc: origin.revision, asc: episode.id],
        limit: 1,
        select: {episode, origin.revision}
      )
    )
  end

  defp origin_kind("slack", source_item_ref, thread_ref)
       when is_binary(source_item_ref) and is_binary(thread_ref) do
    if thread_ref == source_item_ref,
      do: {:channel_root, thread_ref},
      else: {:thread_reply, thread_ref}
  end

  defp origin_kind(_source_kind, _source_item_ref, _thread_ref), do: {:conversation, nil}
end
